class EnableUUID < ActiveRecord::Migration
  def change
    enable_extension 'pgcrypto' unless extension_enabled?('pgcrypto')
  end
end