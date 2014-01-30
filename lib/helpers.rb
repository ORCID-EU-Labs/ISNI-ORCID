# -*- coding: utf-8 -*-

require_relative 'session'
require_relative 'result'

require 'will_paginate'
require 'will_paginate/view_helpers/sinatra'
require 'log4r'

helpers WillPaginate::Sinatra::Helpers

helpers do
  include Session
  include Log4r
  #ap logger

  def logger
    Log4r::Logger['test']    
  end

  def load_config
    @conf ||= YAML.load_file('config/settings.yml')
  end

  def search server, q
    logger.debug "Building query from name variants '#{q.join(' | ')}'"

    # Load up linked, claimed identifier info for the signed-in user, to match against
    # the search results so we can check which records have been claimed already.
    claimed_ids = []
    profile_ids = []
    external_ids = []
    work_ids     = []
    logger.debug "Getting list of claimed IDs in ORCID record for signed-in user #{sign_in_id}: \n" + @orcid_record.ai
    claimed_ids =  (@orcid_record['ids'] || []) +  (@orcid_record['locked_ids']  || [])
    claimed_ids.uniq!    
    claimed_external_ids = @orcid_record['external_ids']
    claimed_work_ids     = @orcid_record['work_ids']          
    
    logger.info "Final list of claimed IDs:\n" + claimed_ids.ai
    profile_ids = @orcid_record['ids']  || []
    profile_ids.uniq!

    results = []
    build_query q do |params|
      logger.info "Hitting the ISNI API with query string based on '#{q.join('|')}'"

      # To page results, provide max no records and start record params too
      params['maximumRecords'] = query_items
      params['startRecord'] = (query_items * (query_page - 1)) + 1
      logger.debug "query params: " + params.ai

      res = server.get '/sru/DB=1.2/', params
      
      # Extract the parts of the ISNI metadata record we need
      parse_isni_response res.body do |isni, uri, family_name, given_names, other_names, works|
        
        # Determine if this ID is claimed already
        claimed = false
        unless @orcid_record['external_ids'].nil?
          claimed = @orcid_record['external_ids'].any? {|h| h["id"] == isni && h["type"] == "ISNI" }
        end
        in_profile = claimed
          
        user_state = {:in_profile => in_profile, :claimed => claimed}

        # Construct a result object for each ISNI record returned from the search
        # NB this first iteration is hardcoded to ingest ISNI records. Need to generalize this
        # and possibly allow for subclasses/callbacks to handle other types of records.        
        result = SearchResult.new :id => isni, :uri => uri, :family_name => family_name, :given_names => given_names,
                                  :other_names => other_names, :works => works, :user_state => user_state
        results.push result
      end
    end
    return results
  end

  
  # Parse the XML response from the search API
  def parse_isni_response res_body
    
    results = []
    parsed_response = MultiXml.parse(res_body)['searchRetrieveResponse']
    #logger.debug "Entire parsed response from ISNI: \n" + parsed_response.ai
    return unless parsed_response['records']
    @total_items = parsed_response['numberOfRecords'].to_i
    records = parsed_response['records']['record']
    records = [records] if !records.kind_of? Array
    
    records.each do |r|  
      rdata = r['recordData']['responseRecord']['ISNIAssigned']
      #logger.debug "full ISNI metadata record: " + rdata.ai
      isni     = rdata['isniUnformatted']
      isni_uri = rdata['isniURI']
      #logger.debug "sources: " + rdata['ISNIMetadata']['sources'].ai

      # ToDo: grab sources list also


      # Collect all personal names into a single master list
      names = rdata['ISNIMetadata']['identity']['personOrFiction']['personalName']
      names.nil? or logger.info "Found #{names.size} personal name(s) in ISNI record"
      name_variants = rdata['ISNIMetadata']['identity']['personOrFiction']['personalNameVariant']
      name_variants.nil? or logger.info "Found #{name_variants.size} personal name variants in ISNI record"
      names = [names] if !names.kind_of? Array
      name_variants = [name_variants] if !name_variants.kind_of? Array      
      namelist = []
      is_first = 1
      family_name = ""
      given_names = ""
      (names + name_variants).each do |pname|    
        next if pname.nil?
        next if pname['surname'] == "" && pname['forename'] == ""
        pnamestring = (pname['surname']||"") + ", " + (pname['forename']||"")
        namelist.push pnamestring

        # We'll arbitrarily grab the 1st name on the list and set as the "primary"        
        if is_first
          logger.info "Setting #{pname['surname']}, #{pname['forename']} as the primary pname"
          family_name = pname['surname']
          given_names = pname['forename']
          is_first = nil
        end

      end

      # there's loads of name duplications in the ISNI records, so let's uniquify the list
      namelist.uniq! 
      if namelist.size == 0 
        logger.info "no names found for ISNI " + isni
        next
      end
      logger.debug "Got total #{namelist.size} personal name(s) after cleaning:"
      namelist.each do |n|
        logger.debug "  - pname: #{n}"
      end

      # And finally set all the names except the first one as other names for this person
      namelist.shift

      # Extract list of associated works in the ISNI profile
      logger.debug "Associated works data in ISNI record: \n" + rdata['ISNIMetadata']['identity']['personOrFiction']['creativeActivity'].ai
      works  = []
      titles = rdata['ISNIMetadata']['identity']['personOrFiction']['creativeActivity']['titleOfWork']
      identifiers = rdata['ISNIMetadata']['identity']['personOrFiction']['creativeActivity']['identifier']
      unless identifiers.nil?
        identifiers = [identifiers] if !identifiers.kind_of? Array
        logger.info "Got #{identifiers.size} work identifiers"
        identifiers.each do |i|
          works <<  {
            'identifier'     => i['identifierValue'],
            'identifierType' => i['identifierType'] }
        end
        works.uniq!
        logger.info "Got a uniquified set of work identifiers associated with ISNI #{isni}:\n" + works.ai
      end
      
      # Execute the block passed in by the caller
      yield isni, isni_uri, family_name, given_names, namelist, works
      
    end
  end

  def lookup_and_add_isbn_metadata! work
    work_id = work['identifier']
    xisbn_url = "http://xisbn.worldcat.org/webservices/xid/isbn/#{work_id}/metadata.js?fl=*"
    logger.info "Retrieving work metadata for ISBN #{work_id}: #{xisbn_url}"
    response = Faraday.get xisbn_url
    result = JSON.parse(response.body)["list"][0]
    #logger.debug "Got work metadata from ISBN #{work_id}:" + result.ai
    work['title']    = result['title']
    work['author']    = result['author']
    work['year']      = result['year']
    work['publisher'] = result['publisher']
    work['url']       = "http://www.worldcat.org/isbn/" + work_id
    
    # A bit of cleanup
    work['author'].gsub! /^\[/, ""
    work['author'].gsub! /(\]|\]\.)$/, ""
  end

  def response_format
    if params.has_key?('format') && params['format'] == 'json'
      'json'
    else
      'html'
    end
  end

  def query_page
    if params.has_key? 'page'
      params['page'].to_i
    else
      1
    end
  end

  def query_items
    if params.has_key? 'items'
      params['items'].to_i
    else
      settings.default_items
    end
  end


  # Set up the request to send to the ISNI API
  def build_query q, &block
    
    # TODO smarter name munging
    #  first generate the namelist, switch around lastname/initials etc.
    #  then build the qstring that ISNI wants

    query_params = {
      # Fixed parameters that are always the same for each request
      'operation' => 'searchRetrieve',
      'recordSchema' => 'isni-b',
      # The query string itself which specific to each API request
      'query' => names2qstring(q)
    }    
    yield query_params
  end
    
  # Prepare the list of names as an URI-escaped query string, just like ISNI wants it
  def names2qstring names
    logger.debug "names for building query string from: \n" + names.ai
    names4query = []
    names.each do |n|
      logger.debug "  -Adding '#{n}' to name list"
      names4query.push 'pica.na=' + '"' + n + '"'
    end
    qstring = names4query.join " OR "
    logger.debug "Final query string:" + qstring     
    return qstring
  end
  
  def sort_term
    if 'publicationYear' == params['sort']
      'publicationYear desc, score desc'
    else
      'score desc'
    end
  end

  def facet_link_not field_name, field_value
    fq = abstract_facet_query
    fq[field_name].delete field_value
    fq.delete(field_name) if fq[field_name].empty?

    link = "#{request.path_info}?q=#{CGI.escape(params['q'])}"
    fq.each_pair do |field, vals|
      link += "&#{field}=#{CGI.escape(vals.join(';'))}"
    end
    link
  end

  def facet_link field_name, field_value
    fq = abstract_facet_query
    fq[field_name] ||= []
    fq[field_name] << field_value

    link = "#{request.path_info}?q=#{CGI.escape(params['q'])}"
    fq.each_pair do |field, vals|
      link += "&#{field}=#{CGI.escape(vals.join(';'))}"
    end
    link
  end

  def facet? field_name
    abstract_facet_query.has_key? field_name
  end


  def search_results solr_result, oauth = nil
    claimed_dois = []
    profile_dois = []

    if signed_in?
      orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
      unless orcid_record.nil?
        claimed_dois = orcid_record['dois'] + orcid_record['locked_dois'] if orcid_record
        profile_dois = orcid_record['dois']
      end
    end

    solr_result['response']['docs'].map do |solr_doc|
      doi = solr_doc['doi']
      in_profile = profile_dois.include?(doi)
      claimed = claimed_dois.include?(doi)
      user_state = {
        :in_profile => in_profile,
        :claimed => claimed
      }
      SearchResult.new solr_doc, solr_result, citations(solr_doc['doi']), user_state
    end
  end


  def scrub_query query_str, remove_short_operators
    query_str = query_str.gsub(/[\"\.\[\]\(\)\-:;\/%]/, ' ')
    query_str = query_str.gsub(/[\+\!\-]/, ' ') if remove_short_operators
    query_str = query_str.gsub(/AND/, ' ')
    query_str = query_str.gsub(/OR/, ' ')
    query_str.gsub(/NOT/, ' ')
  end


  # probably cannot make use of this for non-Solr search index
  def index_stats
    count_result = settings.solr.get settings.solr_select, :params => {
      :q => '*:*',
      :fq => 'has_metadata:true',
      :rows => 0
    }
    dataset_result = settings.solr.get settings.solr_select, :params => {
      :q => 'resourceTypeGeneral:Dataset',
      :rows => 0
    }
    text_result = settings.solr.get settings.solr_select, :params => {
      :q => 'resourceTypeGeneral:Text',
      :rows => 0
    }    
    software_result = settings.solr.get settings.solr_select, :params => {
      :q => 'resourceTypeGeneral:Software',
      :rows => 0
    }
    oldest_result = settings.solr.get settings.solr_select, :params => {
      :q => 'publicationYear:[1 TO *]',
      :rows => 1,
      :sort => 'publicationYear asc'
    }

    stats = []

    stats << {
      :value => count_result['response']['numFound'],
      :name => 'Total number of indexed DOIs',
      :number => true
    }

    stats << {
      :value => dataset_result['response']['numFound'],
      :name => 'Number of indexed datasets',
      :number => true
    }

    stats << {
      :value => text_result['response']['numFound'],
      :name => 'Number of indexed text documents',
      :number => true
    }
    
    stats << {
      :value => software_result['response']['numFound'],
      :name => 'Number of indexed software',
      :number => true
    }

    stats << {
      :value => oldest_result['response']['docs'].first['publicationYear'],
      :name => 'Oldest indexed publication year'
    }

    stats << {
      :value => MongoData.coll('orcids').count({:query => {:updated => true}}),
      :name => 'Number of ORCID profiles updated'
    }

    stats
  end

  def search_link opts
    fields = settings.facet_fields + ['q', 'sort'] # 'filter' ??
    parts = fields.map do |field|
      if opts.has_key? field.to_sym
        "#{field}=#{CGI.escape(opts[field.to_sym])}"
      elsif params.has_key? field
        params[field].split(';').map do |field_value|
          "#{field}=#{CGI.escape(params[field])}"
        end
      end
    end

    "#{request.path_info}?#{parts.compact.flatten.join('&')}"
  end


end

