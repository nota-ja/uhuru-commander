module Uhuru::BoshCommander
  class Clouds < RouteBase

    def initialize(app)
      super

      @cloud_menu = {
          :tab_manage =>  'Manage',
          :tab_virtual_machines => 'Virtual Machines',
          :tab_summary => 'Summary'
      }

      @default_cloud_menu = :tab_manage
      @default_cloud_sub_menu = :networks
    end


    get '/clouds' do
      clouds = []
      CommanderBoshRunner.execute(session) do
        Deployment.deployments_obj.each do |deployment|
          clouds << deployment.status
        end
      end

      render_erb do
        template :clouds
        layout :layout
        var :clouds, clouds
        help 'clouds'
      end
    end

    post '/clouds' do
      clouds = []
      if params["create_cloud_name"] != ''
        CommanderBoshRunner.execute(session) do
          deployment = Deployment.new(params["create_cloud_name"])
          blank_manifest_template = ERB.new(File.read($config[:blank_cf_template]))

          new_manifest = YAML.load(blank_manifest_template.result(binding))

          deployment.save(new_manifest)

          Deployment.deployments_obj.each do |deployment|
            clouds << deployment.status
          end
        end
      end

      redirect '/clouds'
    end

    get '/clouds/:cloud_name' do
      cloud_name = params[:cloud_name]
      deployment_status = {}
      form = nil

      CommanderBoshRunner.execute(session) do
        form = CloudForm.from_cloud_name(cloud_name, nil)
        deployment_status = form.deployment.status
        form.validate? GenericForm::VALUE_TYPE_SAVED
      end

      cloud_summary_help = $config[:help]['cloud_summary'].map do |help_item|
        help_item << 'cloud_tab_summary_div'
      end

      render_erb do
        template :cloud
        layout :layout

        var :form, form
        var :summary, deployment_status
        var :cloud_name, cloud_name
        var :value_type, GenericForm::VALUE_TYPE_SAVED

        help form.help
        help cloud_summary_help
      end
    end

    post '/clouds/:cloud_name' do
      cloud_name = params[:cloud_name]
      is_ok = true
      form = nil
      values_to_show = GenericForm::VALUE_TYPE_FORM
      deployment_status = {}

      cloud_summary_help = $config[:help]['cloud_summary'].map do |help_item|
        help_item << 'cloud_tab_summary_div'
      end

      if params.has_key?("btn_save") || params.has_key?("btn_save_and_deploy")

        CommanderBoshRunner.execute(session) do
          form = CloudForm.from_cloud_name(cloud_name, params)
          is_ok = form.validate?(GenericForm::VALUE_TYPE_FORM)

          if is_ok
            form.generate_volatile_data!
            values_to_show = GenericForm::VALUE_TYPE_VOLATILE
            form.deployment.save(form.get_data(GenericForm::VALUE_TYPE_VOLATILE))

            is_ok = form.validate?(GenericForm::VALUE_TYPE_VOLATILE)
          end
          deployment_status = form.deployment.status
        end

        if params.has_key?("btn_save") || !is_ok
          render_erb do
            template :cloud
            layout :layout

            var :form, form
            var :cloud_name, cloud_name
            var :summary, deployment_status
            var :value_type, values_to_show

            help form.help
            help cloud_summary_help
          end
        elsif params.has_key?("btn_save_and_deploy")
          request_id = CommanderBoshRunner.execute_background(session) do
            begin
              form.deployment.deploy
            rescue Exception => e
              err e.message.to_s
            end
          end

          action_on_done = "Deployment of cloud '#{cloud_name}' finished. Click <a href='/clouds/#{cloud_name}?menu=tab_summary'>here</a> to view cloud summary."
          redirect Logs.log_url request_id, action_on_done
        end
      elsif params.has_key?("btn_tear_down")
        request_id = CommanderBoshRunner.execute_background(session) do
          begin
            deployment = Deployment.new(cloud_name)
            deployment.tear_down
          rescue Exception => e
            err e.message.to_s
          end
        end

        action_on_done = "Tear-down of cloud '#{cloud_name}' finished. Click <a href='/clouds/#{cloud_name}'>here</a> to view cloud configuration."
        redirect Logs.log_url request_id, action_on_done
      elsif params.has_key?("btn_delete")
        request_id = CommanderBoshRunner.execute_background(session) do
          begin
            deployment = Deployment.new(cloud_name)
            deployment.delete
          rescue Exception => e
            err e.message.to_s
          end
        end

        action_on_done = "Delete of cloud '#{cloud_name}' finished. Click <a href='/clouds'>here</a> for cloud management."
        redirect Logs.log_url request_id, action_on_done
      elsif params.has_key?("btn_export")
        params.delete("btn_export")
        send_file Deployment.get_deployment_yml_path(cloud_name), :filename => "#{cloud_name}.yml", :type => 'Application/octet-stream'
      elsif params.has_key?("file_input")
        tempfile = params['file_input'][:tempfile]
        manifest = YAML.load_file(tempfile)
        params.delete("file_input")


        blank_manifest_template = ERB.new(File.read($config[:blank_cf_template]))
        new_manifest = YAML.load(blank_manifest_template.result(binding))

        forms_yml = $config[:forms]

        forms_yml['cloud'].each do |screen|
          screen['fields'].each do |field|
            unless field['type'] == 'separator'

              yml_keys = field['yml_key']

              unless yml_keys.is_a? Array
                yml_keys = [yml_keys]
              end

              yml_keys.each do |key|
                begin
                  new_value = nil
                  eval("new_value=manifest#{key}")
                  if new_value
                    eval("new_manifest#{key} = manifest#{key}")
                  end
                rescue => e
                  $logger.warn "Could not import value #{field['label']} for cloud #{cloud_name}"
                end
              end
            end
          end
        end

        form_params = {}

        CommanderBoshRunner.execute(session) do
          form = CloudForm.from_imported_data(cloud_name, new_manifest)

          form.screens.each do |screen|
            screen.fields.each do |field|
              form_params[field.html_form_id] = field.get_value(GenericForm::VALUE_TYPE_SAVED)
            end
          end

          values_to_show = GenericForm::VALUE_TYPE_FORM
          form = CloudForm.from_cloud_name(cloud_name, form_params)
          form.validate? GenericForm::VALUE_TYPE_FORM
          deployment_status = form.deployment.status
        end

        render_erb do
          template :cloud
          layout :layout

          var :form, form
          var :cloud_name, cloud_name
          var :summary, deployment_status
          var :value_type, values_to_show

          help form.help
          help cloud_summary_help
        end
      end
    end

    get '/clouds/:cloud_name/vms' do
      vms_list = {}

      cloud_name = params[:cloud_name]

      CommanderBoshRunner.execute(session) do
        form = CloudForm.from_cloud_name(cloud_name, nil)
        if form.deployment.get_state() == Deployment::STATE_DEPLOYED
          vms = Vms.new()
          vms_list = vms.list(cloud_name)
        end
      end

      vms_list.to_json
    end
  end
end