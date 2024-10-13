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

  ###
  # class MessageImporter
  #   can be run from rake?
  #   operates on a directory with all the message logs
  #   each file should have one or more messages in it that will be processed
  #   when processing a file is done, update the journal
  #   message file should roll over when it gets too big
  #   for each message to be processed, save it to InfluxDB
  #   on the last message, save it to app db as the last state

  ###
  # class ImporterJournal
  #   file based record of the current folder's import status
  #   each filename has a date of read start, read end, and the last line number processed
  def token
    puts "get new token"

    respond_to do |format|
      format.json { render json: "{'new token for user','server-version':'#{ TuesdayServer::Application::VERSION }'}" }
    end
  end
end
