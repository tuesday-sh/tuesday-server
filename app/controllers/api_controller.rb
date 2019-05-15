class ApiController < ApplicationController
  def index
    agent_status = AgentStatus.create(
      details: params[:host], 
      version: params[:v], 
      agent_time: DateTime.strptime(params[:time],'%s'), 
      package_manager: params[:pkgmgr], 
      message: params[:msg])
    respond_to do |format|
      format.json { render json: "{'got it'}" }
    end
  end
end
