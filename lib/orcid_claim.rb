# -*- coding: utf-8 -*-
require 'nokogiri'
require 'oauth2'
require 'log4r'

require_relative 'data'

class OrcidClaim

  @queue = :orcid

  def logger
    Log4r::Logger['test']    
  end

  def initialize oauth, record, work
    @oauth = oauth
    @record = record
    @work = work
  end

  def self.perform oauth, record, work
    OrcidClaim.new(oauth, record, work).perform
  end
  
  def logger
    Log4r::Logger['test']    
  end

  def perform
    oauth_expired = false

    logger.info "Performing claim, associating ORCID  with external ID OR claiming work ID:"
    logger.debug { "ORCID record:\n"   + @oauth.ai}
    logger.debug { "External bio-record:\n" + @record.ai}
    logger.debug { "Work record: " + @work.ai}
    
    load_config

    # Need to check both since @oauth may or may not have been serialized back and forth from JSON.
    uid = @oauth[:uid] || @oauth['uid']

    opts = {:site => @conf['orcid']['site'], :raise_errors => false  }
    
    client = OAuth2::Client.new( @conf['orcid']['client_id'],  @conf['orcid']['client_secret'], opts)
    token = OAuth2::AccessToken.new(client, @oauth['credentials']['token'])
    headers = {'Accept' => 'application/json'}

    # Choose ORCID API endpoint depending on whether we're POSTIng a work or an external
    api_endpoint = "/v1.1/#{uid}/" + (@work.nil? ? "orcid-bio/external-identifiers" : "orcid-works")
    logger.info "Connecting to ORCID OAuth API, POSTing claim data to #{opts[:site]}#{api_endpoint}"    
    response = token.post(api_endpoint) do |post|
      post.headers['Content-Type'] = 'application/orcid+xml'
      post.body = to_xml
      logger.debug "Final XML to POST to ORCID API: \n" + post.body
    end
    if response.status == 200 || response.status == 201
      return response.status
    else
      logger.error "Bad response from ORCID API:\n  HTTP status=#{response.status}\n  API response body=\n#{response.body}"
      error_msg_api = MultiXml.parse(response.body)['orcid_message']['error_desc']
      raise error_msg_api
    end
  end

  def has_path? hsh, path
    loc = hsh
    path.each do |path_item|
      if loc[path_item]
        loc = loc[path_item]
      else
        loc = nil
        break
      end
    end
    loc != nil
  end

  def orcid_work_type internal_work_type
    case internal_work_type
    when 'journal_article' then 'journal-article'
    when 'conference_paper' then 'conference-proceedings'
    else 'other'
    end
  end

  def pad_date_item item
    result = nil
    if item
      begin
        item_int = item.strip.to_i
        if item_int >= 0 && item_int <= 11
          item_str = item_int.to_s
          if item_str.length < 2
            result = "0" + item_str
          elsif item_str.length == 2
            result = item_str
          end
        end
      rescue StandardError => e
        # Ignore type conversion errors
      end
    end
    result
  end

  def insert_id xml, type, value
    xml.send(:'work-external-identifier') {
      xml.send(:'work-external-identifier-type', type)
      xml.send(:'work-external-identifier-id', value)
    }
  end

  def insert_ids xml
     xml.send(:'work-external-identifiers') {
      insert_id(xml, 'doi', @work['doi'])
      insert_id(xml, 'isbn', @work['proceedings']['isbn']) if has_path?(@work, ['proceedings', 'isbn'])
      insert_id(xml, 'issn', @work['journal']['issn']) if has_path?(@work, ['journal', 'issn'])
    }
  end
  
  def insert_contributors xml
    if @work['contributors'] && !@work['contributors'].count.zero?
      xml.send(:'work-contributors') {
        @work['contributors'].each do |contributor|
          full_name = ""
          full_name = contributor['given_name'] if contributor['given_name']
          full_name += " " + contributor['surname'] if contributor['surname']
          if !full_name.empty?
            xml.contributor {
              xml.send(:'credit-name', full_name)
              # TODO Insert contributor roles and sequence once available
              # in 'dois' mongo collection.
              #xml.send(:'contributor-attributes') {
              #  xml.send(:'contributor-role', 'author')
              #}
            }
          end
        end
      }
    end
  end

  def insert_citation xml
    conn = Faraday.new
    logger.info "Retrieving citation for #{@work['doi']}"
    response = conn.get "http://data.datacite.org/#{@work['doi']}", {}, {
      'Accept' => 'application/x-bibtex'
    }

    citation = response.body.sub(/^@data{/, '@misc{datacite')

    if response.status == 200
      xml.send(:'work-citation') {
        xml.send(:'work-citation-type', 'bibtex')
        xml.citation {
          xml.cdata(citation)
        }
      }
    end
  end


  def insert_extid_common_name xml
    xml.send(:'external-id-common-name', "ISNI")
  end

  def insert_extid_ref xml
    xml.send(:'external-id-reference', @record['id'])    
  end

  def insert_extid_url xml
    xml.send(:'external-id-url', @record['uri'])
  end

  def xml_root_attributes
    
  end

  def insert_work xml
    xml.send(:'orcid-activities') {
      xml.send(:'orcid-works') {
        xml.send(:'orcid-work') {
          xml.send(:'work-title') {
            xml.title(@work['title'])
          }
          xml.send(:'work-citation') {
            xml.send(:'work-citation-type', 'bibtex')
            xml.citation {
              xml.cdata(%Q|@BOOK{#{@work['author'].gsub(/\W+/, '')}_#{@work['year']}_#{@work['identifier']}, 
   isbn = {#{@work['identifier']}}, 
   title = {#{@work['title']}}, 
   url = {#{@work['url']}}, 
   author={#{@work['author']}}, 
   publisher = {#{@work['publisher']}}, 
   year = {#{@work['year']}}, 
   address = {#{@work['city']}}
}|
)
            }
          }
          xml.send(:'work-type', "book")
          xml.send(:'publication-date') {
            xml.year(@work['year'].to_i.to_s)
          }          
          xml.send(:'work-external-identifiers') {
            insert_id(xml, 'isbn', @work['identifier'])
          }

          #insert_contributors(xml)
        }
      }
    }    
  end

  def insert_bio xml
    xml.send(:'orcid-bio') {
      xml.send(:'external-identifiers') {
        xml.send(:'external-identifier') {
          insert_extid_common_name(xml)
          insert_extid_ref(xml)
          insert_extid_url(xml)
        }
      }
    }    
  end

  def to_xml
    root_attributes = {
      :'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
      :'xsi:schemaLocation' => 'http://www.orcid.org/ns/orcid http://orcid.github.com/ORCID-Parent/schemas/orcid-message/1.1/orcid-message-1.1.xsd',
      :'xmlns' => 'http://www.orcid.org/ns/orcid'
    }


    builder = Nokogiri::XML::Builder.new do |xml|
      xml.send(:'orcid-message', root_attributes) {
        xml.send(:'message-version', '1.1')
        xml.send(:'orcid-profile') {

          if(!@work.nil?) 
            insert_work(xml)
          else
            insert_bio(xml)
          end
        }
      }
    end.to_xml
  end

  def load_config
    @conf ||= YAML.load_file('config/settings.yml')
  end
  
  
end
