class PgEnableUuid < ActiveRecord::Migration[7.2]
  if ActiveRecord::Base.connection.adapter_name.downcase == "postgresql"
    def change
      enable_extension 'pgcrypto' unless extension_enabled?('pgcrypto')
    end
  end
end