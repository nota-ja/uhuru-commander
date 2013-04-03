module Uhuru::BoshCommander
  class Logs < RouteBase

    def self.log_url(request_id, action_on_done)
      "logs/#{request_id}?done=#{ CGI.escape Base64.encode64 action_on_done }"
    end

    get '/logs/:stream_id' do
      screen_id = UUIDTools::UUID.random_create.to_s
      CommanderBoshRunner.status_streamer(session).create_screen(params[:stream_id], screen_id)

      action_on_done = params['done']

      render_erb do
        template :logs
        layout :layout
        var :screen_id, screen_id
        var :action, action_on_done
        help 'logs'
      end
    end

    get '/screen/:screen_id' do
      status_streamer = CommanderBoshRunner.status_streamer(session)
      screen_id = params[:screen_id]

      if status_streamer.screen_exists? screen_id
        if status_streamer.screen_done? screen_id
          headers 'X-Commander-Log-Instructions' => 'stop'
          CommanderBoshRunner.status_streamer(session).read_screen(screen_id)
        else
          headers 'X-Commander-Log-Instructions' => 'continue'
          CommanderBoshRunner.status_streamer(session).read_screen(screen_id)
        end
      else
        headers 'X-Commander-Log-Instructions' => 'missing'
      end
    end

    get '/internal_logs' do
      log_file = $config[:logging][:file]
      json = File.read log_file
      logs = []

      Yajl::Parser.parse(json) { |obj|
        logs << obj
      }

      render_erb do
        template :internal_logs
        layout :layout
        var :logs, logs
        help 'internal_logs'
      end
    end

    get '/vmlog/:deployment/:job/:index' do
      deployment = params[:deployment]
      job = params[:job]
      index = params[:index]
      resource_id = ''

      request_id = CommanderBoshRunner.execute_background(session) do
        begin
          deployment = Deployment.new(deployment)
          #TODO !! set file path!!
          deployment.get_vm_logs(job, index, "file_path")
        rescue Exception => e
          err e.message.to_s
        end
      end

      action_on_done = "Log tarball has been generated. Click <a href='/vmlog-dl/#{resource_id}'>here</a> to download it."
      redirect Logs.log_url(request_id, action_on_done)
    end
  end
end