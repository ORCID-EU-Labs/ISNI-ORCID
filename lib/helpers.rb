# -*- coding: utf-8 -*-

require_relative 'session'
require_relative 'result'

require 'log4r'

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

    # Load up profile info for the signed-in user
    claimed_ids = []
    profile_ids = []

    if signed_in?
      orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
      unless orcid_record.nil? 
        logger.debug "Getting list of claimed IDs in ORCID record for signed-in user #{sign_in_id}: \n" + orcid_record.ai
        if orcid_record
          claimed_ids =  (orcid_record['ids'] || []) +  (orcid_record['locked_ids']  || [])
          claimed_ids.uniq!
          logger.info "Final list of claimed IDs:\n" + claimed_ids.ai
          profile_ids = orcid_record['ids']  || []
          profile_ids.uniq!
        end
      end
    end

    results = []
    build_query q do |params|
      logger.info "Hitting the ISNI API with query string based on '#{q.join('|')}'"
      logger.debug "query params: " + params.ai
      res = server.get '/sru/DB=1.2/', params
      #logger.debug "Got response obj " + res.ai
      #logger.debug "Full response body: " + res.body
      parse_isni_response res.body do |isni, family_name, given_names, other_names|

        # Construct a result object for each ISNI record returned from the search
        # NB this first iteration is hardcoded to ingest ISNI records. Need to generalize this
        # and possibly allow for subclasses/callbacks to handle other types of records.        
        in_profile = profile_ids.include?(isni)
        claimed = claimed_ids.include?(isni)
      
        user_state = {:in_profile => in_profile, :claimed => claimed}      
        result = SearchResult.new :id => isni, :family_name => family_name, :given_names => given_names, 
                                  :other_names => other_names, :user_state => user_state
        logger.debug "created result obj: " + result.ai
        results.push result
      end
    end
    return results
  end
  
  # Parse the XML response from the search API
  def parse_isni_response res_body
    
    results = []
    parsed_response = MultiXml.parse(res_body)['searchRetrieveResponse']
    return unless parsed_response['records']
    records = parsed_response['records']['record']
    records = [records] if !records.kind_of? Array
    
    records.each do |r|  
      rdata = r['recordData']['responseRecord']['ISNIAssigned']
      #logger.debug "full ISNI metadata record: " + rdata.ai
      isni     = rdata['isniUnformatted']
      isni_uri = rdata['isniURI']
      logger.debug "sources: " + rdata['ISNIMetadata']['sources'].ai

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
        #logger.debug "  - adding pname: --#{pnamestring}--"
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

      # Execute the block passed in by the caller
      yield isni, family_name, given_names, namelist

      # ToDo later: deal with the works in the ISNI profile      
      #puts "Associated works:"
      #rdata['ISNIMetadata']['identity']['personOrFiction']['creativeActivity'].each do |cwork|
        
        # foreach title (!!!??)
        #logger.debug "  - Work: #{cwork['titleOfWork']['title']}, #{pname['forename']}"
        
        # foreach identifiers
      #end
    end
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
    
    puts "about to yield"
    yield query_params #, ctype
  end
    
  # Prepare the list of names as an URI-escaped query string, just like ISNI wants it
  def names2qstring names
    logger.debug "names for building query string from: \n" + names.ai
    names4query = []
    names.each do |n|
      logger.debug "  -Adding #{n} to name list"
      #names4query.push 'pica.nw=' + URI.escape('"' + n + '"') 
      names4query.push 'pica.nw=' + '"' + n + '"'
    end
    qstring = names4query.join " OR "
    logger.debug "Final query string:" + qstring     
    return qstring
    #example: 'pica.nw="thorisson, hermann" OR pica.nw="jones"';
  end
  


  def sort_term
    if 'publicationYear' == params['sort']
      'publicationYear desc, score desc'
    else
      'score desc'
    end
  end





  def search_query
    fq = facet_query
    query  = {
      :sort => sort_term,
      :q => query_terms,
      :fl => query_columns,
      :rows => query_rows,
      :facet => settings.facet ? 'true' : 'false',
      'facet.field' => settings.facet_fields, 
      'facet.mincount' => 1,
      :hl => settings.highlighting ? 'true' : 'false',
      'hl.fl' => 'hl_*',
      'hl.simple.pre' => '<span class="hl">',
      'hl.simple.post' => '</span>',
      'hl.mergeContinuous' => 'true',
      'hl.snippets' => 10,
      'hl.fragsize' => 0
    }

    query['fq'] = fq unless fq.empty?
    query
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


  # Modify to work with claimed profiles, rather than claimed works/DOIs
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

