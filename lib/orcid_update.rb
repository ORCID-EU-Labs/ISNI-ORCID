# -*- coding: utf-8 -*-
require 'nokogiri'
require 'oauth2'
require 'log4r'

require_relative 'data'

class OrcidUpdate
  @queue = :orcid

  def initialize oauth
    @oauth = oauth
  end

  def self.perform oauth
    OrcidUpdate.new(oauth).perform
  end
  
  def logger
    Log4r::Logger['test']    
  end

  def perform
    oauth_expired = false

    begin
      load_config
      
      # Need to check both since @oauth may or may not have been serialized back and forth from JSON.
      uid = @oauth[:uid] || @oauth['uid']
      
      logger.info "Updating user record with info for ORCiD #{uid}"

      #opts = {:site => @conf['orcid']['site']}
      #client = OAuth2::Client.new(@conf['orcid']['client_id'], @conf['orcid']['client_secret'], opts)
      #token = OAuth2::AccessToken.new(client, @oauth['credentials']['token'])
      headers = {'Accept' => 'application/json'}
      logger.info "GETing profile info via ORCID API for #{uid}"
      response = Faraday.get "http://pub.sandbox-1.orcid.org/" + uid, {}, headers

      # response = token.get "/#{uid}/orcid-profile", {:headers => headers}

      if response.status == 200
        response_json = JSON.parse(response.body)
        logger.debug "Parsed JSON response: " + response_json.ai

        # ToDo!! need 2x calls here, one to get the works IDs as before and another for the external IDs
        parsed_dois = parse_dois(response_json)
        query = {:orcid => uid}
        orcid_record = MongoData.coll('orcids').find_one(query)

        if orcid_record
          logger.debug "Found existing ORCID record to update:" + orcid_record.ai
          orcid_record['dois'] = parsed_dois
          MongoData.coll('orcids').save(orcid_record)
        else
          doc = {:orcid => uid, :dois => parsed_dois, :locked_dois => []}
          logger.debug "Creating new ORCID record: " + doc.ai
          MongoData.coll('orcids').insert(doc)
        end
      else
        oauth_expired = true
      end
    rescue StandardError => e
      logger.debug "An error occured: #{e}"
    end

    !oauth_expired
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

  def parse_dois json
    if !has_path?(json, ['orcid-profile', 'orcid-activities'])
      []
    else
      works = json['orcid-profile']['orcid-activities']['orcid-works']['orcid-work']

      extracted_dois = works.map do |work_loc|
        doi = nil
        if has_path?(work_loc, ['work-external-identifiers', 'work-external-identifier'])
          ids_loc = work_loc['work-external-identifiers']['work-external-identifier']

          ids_loc.each do |id_loc|
            id_type = id_loc['work-external-identifier-type']
            id_val = id_loc['work-external-identifier-id']['value']

            if id_type.upcase == 'DOI'
              doi = id_val
            end
          end

        end
        doi
      end

      extracted_dois.compact
    end
  end
  
  def load_config
    @conf ||= YAML.load_file('config/settings.yml')
  end
end

