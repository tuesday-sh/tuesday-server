class ApiController < ApplicationController
  protect_from_forgery with: :null_session

  def message
    puts params[:token]
    # todo: parse the post params into an AgentStatus then write it to a file
    status = AgentStatus.new
    status.details = params[:host]
    status.version = params[:v]
    status.agent_time = DateTime.strptime(params[:time],'%s')
    status.package_manager = params[:pkgmgr]
    status.message = params[:msg]

    open('statuses/status_' + params[:token] + '.txt', 'a') do |f|
      f << status.to_json
      f << "\n"
    end

    respond_to do |format|
      format.json { render json: "{'got it','server-version':'#{ TuesdayServer::Application::VERSION }'}" }
    end
    # todo: return error if token is missing
    # render error: {error: 'Token missing'}

    # todo: parse status.message into package state snapshot
    #   package updates: count
    #   packages with updates available: list
    # save package state snapshot to app db
  end

  ###
  # def import_agent_status
  #  todo: read the agent status files
  #    insert the params into influxdb
  #    parse packages with updates available list
  #    insert package current version and available version into influxdb
  #    if a package was previously logged as needing update but it's not in the latest status update, then it was updated?

  def token
    puts "get new token"

    respond_to do |format|
      format.json { render json: "{'new token for user','server-version':'#{ TuesdayServer::Application::VERSION }'}" }
    end
  end
end
