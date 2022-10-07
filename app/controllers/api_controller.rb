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

    render json: "{'got it'}"
    # render error: {error: 'Token missing'}
  end
end
