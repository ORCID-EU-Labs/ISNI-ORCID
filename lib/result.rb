# -*- coding: utf-8 -*-

require 'cgi'
require 'log4r'

# Simplified result based on the earlier CrossRef/DataCite works model. Its main
# purpose is to transform an externally-retrieved biographic profile from an idio-
# syncratic structure into a standard,lowest-common-denominator structure.

class SearchResult

  PROPERTIES = [ :id, :uri, :given_names, :family_name, :other_names ]
  attr_accessor *PROPERTIES

  def initialize args

    @id              = args[:id]
    @uri             = args[:uri]
    @given_names     = args[:given_names]
    @family_name     = args[:family_name]
    @other_names     = args[:other_names]
    @works           = args[:works]
    user_state       = args[:user_state]
    @user_claimed    = user_state[:claimed]
    @in_user_profile = user_state[:in_profile]

    # Insert/update record in MongoDB
    logger.info "storing #{@id} in mongo collection 'bios'"
    MongoData.coll('bios').update({ id: @id }, {id: @id,
                                                uri: @uri,
                                                given_names: @given_names,
                                                family_name: @family_name,
                                                other_names: @other_names,
                                                works: @works},
                                               { :upsert => true })
    

  end
 
  def user_claimed?
    @user_claimed
  end
  
  def in_user_profile?
    @in_user_profile
  end
  
end

