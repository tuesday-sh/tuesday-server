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
    # render error: {error: 'Token missing'}
  end

  def token
    puts "get new token"

    respond_to do |format|
      format.json { render json: "{'new token for user','server-version':'#{ TuesdayServer::Application::VERSION }'}" }
    end
  end
end
