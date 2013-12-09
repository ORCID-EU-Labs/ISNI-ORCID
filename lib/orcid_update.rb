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
      response = Faraday.get "http://pub.sandbox-1.orcid.org/v1.1/" + uid, {}, headers

      # response = token.get "/#{uid}/orcid-profile", {:headers => headers}

      if response.status == 200
        response_json = JSON.parse(response.body)
        logger.debug "Got response JSON from ORCID:\n" + response_json.ai

        # ToDo!! for later, need 2x calls here, one to get the works IDs as before and another for the external IDs
        parsed_external_ids = parse_external_ids(response_json)
        query = {:orcid => uid}
        orcid_record = MongoData.coll('orcids').find_one(query)

        if orcid_record
          logger.debug "Found existing ORCID record to update:" + orcid_record.ai
          logger.debug "Updating with external IDs: \n" + parsed_external_ids.ai
          orcid_record['ids'] = parsed_external_ids
          MongoData.coll('orcids').save(orcid_record)
        else
          doc = {:orcid => uid, :ids => parsed_dois, :locked_ids => []}
          logger.debug "Creating new ORCID record: " + doc.ai
          MongoData.coll('orcids').insert(doc)
        end
      else
        oauth_expired = true
      end
    rescue StandardError => e
      logger.debug "An error occured: #{e}:\n" + e.ai
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

  def parse_external_ids json
    logger.debug "Checking if JSON includes any external ID info"
    if !has_path?(json, ['orcid-profile', 'orcid-bio', 'external-identifiers'])
      logger.info "No external IDs for ORCID"
      return []
    else
      ids = json['orcid-profile']['orcid-bio']['external-identifiers']['external-identifier']
      
      extracted_ids = ids.map do |id|
        id['external-id-reference']['value']
      end
      return extracted_ids.compact
    end
  end
  
  def load_config
    @conf ||= YAML.load_file('config/settings.yml')
  end
end

