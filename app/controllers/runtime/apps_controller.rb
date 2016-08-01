require 'presenters/system_env_presenter'
require 'queries/v2/app_query'
require 'actions/v2/app_stage'

module VCAP::CloudController
  class AppsController < RestController::ModelController
    def self.dependencies
      [:app_event_repository, :droplet_blobstore, :stagers]
    end

    define_attributes do
      attribute :enable_ssh,              Message::Boolean, default: nil
      attribute :buildpack,               String,           default: nil
      attribute :command,                 String,           default: nil
      attribute :console,                 Message::Boolean, default: false
      attribute :diego,                   Message::Boolean, default: nil
      attribute :docker_image,            String,           default: nil
      attribute :docker_credentials_json, Hash,             default: {}, redact_in: [:create, :update]
      attribute :debug,                   String,           default: nil
      attribute :disk_quota,              Integer,          default: nil
      attribute :environment_json,        Hash,             default: {}
      attribute :health_check_type,       String,           default: 'port'
      attribute :health_check_timeout,    Integer,          default: nil
      attribute :instances,               Integer,          default: 1
      attribute :memory,                  Integer,          default: nil
      attribute :name,                    String
      attribute :production,              Message::Boolean, default: false
      attribute :state,                   String,           default: 'STOPPED'
      attribute :detected_start_command,  String,           exclude_in: [:create, :update]
      attribute :ports,                   [Integer],        default: nil

      to_one :space
      to_one :stack, optional_in: :create

      to_many :routes,              exclude_in: [:create, :update], route_for: :get
      to_many :events,              exclude_in: [:create, :update], link_only: true
      to_many :service_bindings,    exclude_in: [:create, :update]
      to_many :route_mappings,      exclude_in: [:create, :update], link_only: true, route_for: :get
    end

    query_parameters :name, :space_guid, :organization_guid, :diego, :stack_guid

    get '/v2/apps/:guid/env', :read_env

    def read_env(guid)
      FeatureFlag.raise_unless_enabled!(:env_var_visibility)
      app = find_guid_and_validate_access(:read_env, guid, App)
      FeatureFlag.raise_unless_enabled!(:space_developer_env_var_visibility)

      vcap_application = VCAP::VarsBuilder.new(app).to_hash

      [
        HTTP::OK,
        {},
        MultiJson.dump({
          staging_env_json:     EnvironmentVariableGroup.staging.environment_json,
          running_env_json:     EnvironmentVariableGroup.running.environment_json,
          environment_json:     app.environment_json,
          system_env_json:      SystemEnvPresenter.new(app.all_service_bindings).system_env,
          application_env_json: { 'VCAP_APPLICATION' => vcap_application },
        }, pretty: true)
      ]
    end

    def self.translate_validation_exception(e, attributes)
      space_and_name_errors  = e.errors.on([:space_guid, :name])
      memory_errors          = e.errors.on(:memory)
      instance_number_errors = e.errors.on(:instances)
      app_instance_limit_errors = e.errors.on(:app_instance_limit)
      state_errors           = e.errors.on(:state)
      docker_errors          = e.errors.on(:docker)
      diego_to_dea_errors    = e.errors.on(:diego_to_dea)

      if space_and_name_errors
        CloudController::Errors::ApiError.new_from_details('AppNameTaken', attributes['name'])
      elsif memory_errors
        translate_memory_validation_exception(memory_errors)
      elsif instance_number_errors
        CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Number of instances less than 0')
      elsif app_instance_limit_errors
        if app_instance_limit_errors.include?(:space_app_instance_limit_exceeded)
          CloudController::Errors::ApiError.new_from_details('SpaceQuotaInstanceLimitExceeded')
        else
          CloudController::Errors::ApiError.new_from_details('QuotaInstanceLimitExceeded')
        end
      elsif state_errors
        CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Invalid app state provided')
      elsif docker_errors && docker_errors.include?(:docker_disabled)
        CloudController::Errors::ApiError.new_from_details('DockerDisabled')
      elsif diego_to_dea_errors
        CloudController::Errors::ApiError.new_from_details('MultipleAppPortsMappedDiegoToDea')
      else
        CloudController::Errors::ApiError.new_from_details('AppInvalid', e.errors.full_messages)
      end
    end

    def self.translate_memory_validation_exception(memory_errors)
      if memory_errors.include?(:space_quota_exceeded)
        CloudController::Errors::ApiError.new_from_details('SpaceQuotaMemoryLimitExceeded')
      elsif memory_errors.include?(:space_instance_memory_limit_exceeded)
        CloudController::Errors::ApiError.new_from_details('SpaceQuotaInstanceMemoryLimitExceeded')
      elsif memory_errors.include?(:quota_exceeded)
        CloudController::Errors::ApiError.new_from_details('AppMemoryQuotaExceeded')
      elsif memory_errors.include?(:zero_or_less)
        CloudController::Errors::ApiError.new_from_details('AppMemoryInvalid')
      elsif memory_errors.include?(:instance_memory_limit_exceeded)
        CloudController::Errors::ApiError.new_from_details('QuotaInstanceMemoryLimitExceeded')
      end
    end

    def inject_dependencies(dependencies)
      super
      @app_event_repository = dependencies.fetch(:app_event_repository)
      @blobstore            = dependencies.fetch(:droplet_blobstore)
      @stagers              = dependencies.fetch(:stagers)
    end

    def delete(guid)
      app = find_guid_and_validate_access(:delete, guid)
      space = app.space

      if !recursive_delete? && app.service_bindings.present?
        raise CloudController::Errors::ApiError.new_from_details('AssociationNotEmpty', 'service_bindings', app.class.table_name)
      end

      AppDelete.new(SecurityContext.current_user.guid, SecurityContext.current_user_email).delete(app.app)

      @app_event_repository.record_app_delete_request(
        app,
        space,
        SecurityContext.current_user.guid,
        SecurityContext.current_user_email,
        recursive_delete?)

      [HTTP::NO_CONTENT, nil]
    end

    get '/v2/apps/:guid/droplet/download', :download_droplet
    def download_droplet(guid)
      app = find_guid_and_validate_access(:read, guid)
      blob_dispatcher.send_or_redirect(guid: app.current_droplet.try(:blobstore_key))
    rescue CloudController::Errors::BlobNotFound
      raise CloudController::Errors::ApiError.new_from_details('ResourceNotFound', "Droplet not found for app with guid #{app.guid}")
    end

    private

    def blob_dispatcher
      BlobDispatcher.new(blobstore: @blobstore, controller: self)
    end

    def before_update(app)
      verify_enable_ssh(app.space)
      updated_diego_flag = request_attrs['diego']
      ports = request_attrs['ports']
      ignore_empty_ports! if ports == []
      if should_warn_about_changed_ports?(app.diego, updated_diego_flag, ports)
        add_warning('App ports have changed but are unknown. The app should now listen on the port specified by environment variable PORT.')
      end
    end

    def ignore_empty_ports!
      @request_attrs = @request_attrs.deep_dup
      @request_attrs.delete 'ports'
      @request_attrs.freeze
    end

    def should_warn_about_changed_ports?(old_diego, new_diego, ports)
      !new_diego.nil? && old_diego && !new_diego && ports.nil?
    end

    def verify_enable_ssh(space)
      app_enable_ssh = request_attrs['enable_ssh']
      global_allow_ssh = VCAP::CloudController::Config.config[:allow_app_ssh_access]
      ssh_allowed = global_allow_ssh && (space.allow_ssh || roles.admin?)

      if app_enable_ssh && !ssh_allowed
        raise CloudController::Errors::ApiError.new_from_details(
          'InvalidRequest',
          'enable_ssh must be false due to global allow_ssh setting',
          )
      end
    end

    def after_update(app)
      stager_response = app.last_stager_response
      if stager_response.respond_to?(:streaming_log_url) && stager_response.streaming_log_url
        set_header('X-App-Staging-Log', stager_response.streaming_log_url)
      end

      if app.dea_update_pending?
        Dea::Client.update_uris(app)
      end

      @app_event_repository.record_app_update(app, app.space, SecurityContext.current_user.guid, SecurityContext.current_user_email, request_attrs)
    end

    # rubocop:disable MethodLength
    # rubocop:disable Metrics/CyclomaticComplexity
    def update(guid)
      json_msg = self.class::UpdateMessage.decode(body)
      @request_attrs = json_msg.extract(stringify_keys: true)
      logger.debug 'cc.update', guid: guid, attributes: redact_attributes(:update, request_attrs)
      raise InvalidRequest unless request_attrs

      app = find_guid(guid)
      v3_app = app.app

      before_update(app)

      model.db.transaction do
        app.lock!
        v3_app.lock!

        validate_access(:read_for_update, app, request_attrs)
        validate_not_changing_lifecycle_type!(app, request_attrs)

        buildpack_type_requested = request_attrs.key?('buildpack') || request_attrs.key?('stack_guid')

        v3_app.name = request_attrs['name'] if request_attrs.key?('name')
        v3_app.space_guid = request_attrs['space_guid'] if request_attrs.key?('space_guid')
        v3_app.environment_variables = request_attrs['environment_json'] if request_attrs.key?('environment_json')

        if buildpack_type_requested
          v3_app.lifecycle_data.buildpack = request_attrs['buildpack'] if request_attrs.key?('buildpack')

          if request_attrs.key?('stack_guid')
            v3_app.lifecycle_data.stack = Stack.find(guid: request_attrs['stack_guid']).try(:name)
            v3_app.update(droplet: nil)
            app.reload
          end
        elsif request_attrs.key?('docker_image') && !case_insensitive_equals(app.docker_image, request_attrs['docker_image'])
          create_message = PackageCreateMessage.new({ type: 'docker', app_guid: v3_app.guid, data: { image: request_attrs['docker_image'] } })
          creator        = PackageCreate.new(SecurityContext.current_user.guid, SecurityContext.current_user_email)
          creator.create(create_message)
        end

        app.production              = request_attrs['production'] if request_attrs.key?('production')
        app.memory                  = request_attrs['memory'] if request_attrs.key?('memory')
        app.instances               = request_attrs['instances'] if request_attrs.key?('instances')
        app.disk_quota              = request_attrs['disk_quota'] if request_attrs.key?('disk_quota')
        app.state                   = request_attrs['state'] if request_attrs.key?('state') # this triggers model validations
        app.command                 = request_attrs['command'] if request_attrs.key?('command')
        app.console                 = request_attrs['console'] if request_attrs.key?('console')
        app.debug                   = request_attrs['debug'] if request_attrs.key?('debug')
        app.health_check_type       = request_attrs['health_check_type'] if request_attrs.key?('health_check_type')
        app.health_check_timeout    = request_attrs['health_check_timeout'] if request_attrs.key?('health_check_timeout')
        app.diego                   = request_attrs['diego'] if request_attrs.key?('diego')
        app.enable_ssh              = request_attrs['enable_ssh'] if request_attrs.key?('enable_ssh')
        app.docker_credentials_json = request_attrs['docker_credentials_json'] if request_attrs.key?('docker_credentials_json')
        app.ports                   = request_attrs['ports'] if request_attrs.key?('ports')
        app.route_guids             = request_attrs['route_guids'] if request_attrs.key?('route_guids')

        validate_package_is_uploaded!(app)

        app.save
        v3_app.save
        v3_app.lifecycle_data.save && validate_buildpack!(app.reload) if buildpack_type_requested
        v3_app.reload

        if request_attrs.key?('state')
          case request_attrs['state']
          when 'STARTED'
            AppStart.new(SecurityContext.current_user, SecurityContext.current_user_email).start(v3_app)
          when 'STOPPED'
            AppStop.new(SecurityContext.current_user, SecurityContext.current_user_email).stop(v3_app)
          end
        end

        app.reload
        validate_access(:update, app, request_attrs)
      end

      if request_attrs.key?('state') && app.needs_staging?
        V2::AppStage.new(
          user:       SecurityContext.current_user,
          user_email: SecurityContext.current_user_email,
          stagers:    @stagers
        ).stage(app)
      end

      after_update(app)

      [HTTP::CREATED, object_renderer.render_json(self.class, app, @opts)]
    end
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable MethodLength

    # rubocop:disable MethodLength
    def create
      json_msg = self.class::CreateMessage.decode(body)

      @request_attrs = json_msg.extract(stringify_keys: true)

      logger.debug 'cc.create', model: self.class.model_class_name, attributes: redact_attributes(:create, request_attrs)

      space = VCAP::CloudController::Space[guid: request_attrs['space_guid']]
      verify_enable_ssh(space)

      app = nil
      model.db.transaction do
        v3_app = AppModel.create(
          name:                  request_attrs['name'],
          space_guid:            request_attrs['space_guid'],
          environment_variables: request_attrs['environment_json'],
        )

        buildpack_type_requested = request_attrs.key?('buildpack') || request_attrs.key?('stack_guid')
        if buildpack_type_requested || !request_attrs.key?('docker_image')
          stack = request_attrs['stack_guid'] ? Stack.find(guid: request_attrs['stack_guid']) : Stack.default
          v3_app.buildpack_lifecycle_data = BuildpackLifecycleDataModel.new(
            buildpack: request_attrs['buildpack'],
            stack:     stack.try(:name),
          )
          v3_app.save
        end

        if request_attrs.key?('docker_image')
          create_message = PackageCreateMessage.new({ type: 'docker', app_guid: v3_app.guid, data: { image: request_attrs['docker_image'] } })
          creator        = PackageCreate.new(SecurityContext.current_user.guid, SecurityContext.current_user_email)
          creator.create(create_message)
        end

        app = App.new(
          guid:                    v3_app.guid,
          production:              request_attrs['production'],
          memory:                  request_attrs['memory'],
          instances:               request_attrs['instances'],
          disk_quota:              request_attrs['disk_quota'],
          state:                   request_attrs['state'],
          command:                 request_attrs['command'],
          console:                 request_attrs['console'],
          debug:                   request_attrs['debug'],
          health_check_type:       request_attrs['health_check_type'],
          health_check_timeout:    request_attrs['health_check_timeout'],
          diego:                   request_attrs['diego'],
          enable_ssh:              request_attrs['enable_ssh'],
          docker_credentials_json: request_attrs['docker_credentials_json'],
          ports:                   request_attrs['ports'],
          route_guids:             request_attrs['route_guids'],
          app:                     v3_app
        )

        validate_buildpack!(app)
        validate_package_is_uploaded!(app)

        app.save

        validate_access(:create, app, request_attrs)
      end

      @app_event_repository.record_app_create(
        app,
        app.space,
        SecurityContext.current_user.guid,
        SecurityContext.current_user_email,
        request_attrs)

      [
        HTTP::CREATED,
        { 'Location' => "#{self.class.path}/#{app.guid}" },
        object_renderer.render_json(self.class, app, @opts)
      ]
    end
    # rubocop:enable MethodLength

    put '/v2/apps/:app_guid/routes/:route_guid', :add_route
    def add_route(app_guid, route_guid)
      logger.debug "cc.association.add", guid: app_guid, association: 'routes', other_guid: route_guid
      @request_attrs = { 'route' => route_guid, verb: 'add', relation: 'routes', related_guid: route_guid }

      app = find_guid(app_guid, App)
      validate_access(:read_related_object_for_update, app, request_attrs)

      before_update(app)

      route = Route.find(guid: request_attrs['route'])
      raise CloudController::Errors::ApiError.new_from_details('RouteNotFound', route_guid) unless route

      begin
        V2::RouteMappingCreate.new(SecurityContext.current_user, SecurityContext.current_user_email, route, app).add(request_attrs)
      rescue RouteMappingCreate::DuplicateRouteMapping
        # the route is already mapped, consider the request successful
      rescue V2::RouteMappingCreate::TcpRoutingDisabledError
        raise CloudController::Errors::ApiError.new_from_details('TcpRoutingDisabled')
      rescue V2::RouteMappingCreate::RouteServiceNotSupportedError
        raise CloudController::Errors::InvalidRouteRelation.new("#{route.guid} - Route services are only supported for apps on Diego")
      rescue RouteMappingCreate::SpaceMismatch
        raise CloudController::Errors::InvalidRouteRelation.new(route.guid)
      end

      after_update(app)

      [HTTP::CREATED, object_renderer.render_json(self.class, app, @opts)]
    end

    def get_filtered_dataset_for_enumeration(model, ds, qp, opts)
      AppQuery.filtered_dataset_from_query_params(model, ds, qp, opts)
    end

    def filter_dataset(dataset)
      dataset.where(type: 'web')
    end

    def validate_buildpack!(app)
      if app.buildpack.custom? && custom_buildpacks_disabled?
        raise CloudController::Errors::ApiError.new_from_details('AppInvalid', 'custom buildpacks are disabled')
      end
    end

    def custom_buildpacks_disabled?
      VCAP::CloudController::Config.config[:disable_custom_buildpacks]
    end

    def validate_not_changing_lifecycle_type!(app, request_attrs)
      buildpack_type_requested = request_attrs.key?('buildpack') || request_attrs.key?('stack_guid')
      docker_type_requested = request_attrs.key?('docker_image')

      type_is_docker = app.app.lifecycle_type == DockerLifecycleDataModel::LIFECYCLE_TYPE
      type_is_buildpack = !type_is_docker

      if (type_is_docker && buildpack_type_requested) || (type_is_buildpack && docker_type_requested)
        raise CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Lifecycle type cannot be changed')
      end
    end

    define_messages
    define_routes

    def case_insensitive_equals(str1, str2)
      str1.casecmp(str2) == 0
    end

    def validate_package_is_uploaded!(app)
      if app.needs_package_in_current_state? && !app.package_hash
        raise CloudController::Errors::ApiError.new_from_details('AppPackageInvalid', 'bits have not been uploaded')
      end
    end
  end
end
