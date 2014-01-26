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

      opts = {:site => @conf['orcid']['site']}
      logger.info "Connecting to ORCID OAuth API at site #{opts[:site]} to get profile data for #{uid}"
      client = OAuth2::Client.new( @conf['orcid']['client_id'],  @conf['orcid']['client_secret'], opts)
      token = OAuth2::AccessToken.new(client, @oauth['credentials']['token'])
      headers = {'Accept' => 'application/json'}
      response = token.get "/v1.1/#{uid}/orcid-profile", {:headers => headers}

      if response.status == 200
        response_json = JSON.parse(response.body)
        # logger.debug "Got response JSON from ORCID:\n" + response_json.ai

        parsed_external_ids = parse_external_ids(response_json)
        parsed_work_ids     = parse_work_ids(response_json)
        query = {:orcid => uid}
        orcid_record = MongoData.coll('orcids').find_one(query)

        if orcid_record
          logger.debug "Found existing ORCID record to update:" + orcid_record.ai
          orcid_record['external_ids'] = parsed_external_ids
          orcid_record['work_ids'] = parsed_work_ids
          orcid_record['locked_ids'] = parsed_external_ids
          logger.debug "Saving this updated ORCID record:" + orcid_record.ai
          MongoData.coll('orcids').save(orcid_record)
        else
          doc = {:orcid => uid, :ids => parsed_external_ids, :locked_ids => []}
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
    logger.debug "Checking if JSON includes any external ID entries"
    if !has_path?(json, ['orcid-profile', 'orcid-bio', 'external-identifiers'])
      logger.info "No external IDs for ORCID"
      return []
    else      
      extracted_ids = []
      ids = json['orcid-profile']['orcid-bio']['external-identifiers']['external-identifier']
      ids.each do |id|
        extracted_ids << {'id'   => id['external-id-reference']['value'],
                          'type' => id['external-id-common-name']['value'],
                          'uri'  => id['external-id-url']['value']}
      end
      return extracted_ids
    end
  end

  def parse_work_ids json
    logger.debug "Checking if JSON includes any work ID entries"
    if !has_path?(json, ['orcid-profile', 'orcid-activities', 'orcid-works'])
      logger.info "No work IDs for ORCID"
      return []
    else
      extracted_ids = []
      works = json['orcid-profile']['orcid-activities']['orcid-works']['orcid-work']
      works.each do |work|
        if has_path?(work, ['work-external-identifiers', 'work-external-identifier'])
          ids = work['work-external-identifiers']['work-external-identifier']
          ids.each do |id|
            extracted_ids << {'type'   => id['work-external-identifier-type'],
                              'id'     => id['work-external-identifier-id']['value']}
          end            
        end
      end
      return extracted_ids
    end
  end

  
  def load_config
    @conf ||= YAML.load_file('config/settings.yml')
  end
end

