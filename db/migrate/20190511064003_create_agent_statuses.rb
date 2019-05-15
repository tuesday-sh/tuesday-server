class CreateAgentStatuses < ActiveRecord::Migration[5.2]
  def change
    create_table :agent_statuses do |t|
      t.string :details
      t.string :version
      t.timestamp :agent_time
      t.string :package_manager
      t.string :message

      t.timestamps
    end
  end
end
