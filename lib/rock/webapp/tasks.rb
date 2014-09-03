module Rock
    module WebApp

        def self.install_port_writer_clean_loop(period = 5)
            @port_writer_clean_loop_timer ||=
                EM.add_periodic_timer period do
                    PortWriters::clean()
                end
        end
        
        class PortWriters
            require 'thread'
            @writers = {}
            @mutex = Mutex.new
                    
            class PortWriterEntry
                @writer = nil
                @timestamp = nil
                @lifetime_s = nil; 
                @port = nil
                
                def initialize(port, lifetime_seconds)
                    @timestamp = Time.now().to_i
                    @lifetime_s = lifetime_seconds
                    @writer = port.writer
                    @port = port
                end
                
                def write(obj)
                    @timestamp = Time.now().to_i
                    @writer.write(obj)
                end
                
                def expired?
                    #puts "unused #{(Time.now().to_i - @timestamp)}"
                    (Time.now().to_i - @timestamp) > @lifetime_s
                end
                
            end
        
            def self.addWriter(port, name_service, name, port_name, lifetime_seconds)
                puts "added writer with #{lifetime_seconds} timeout"
                entry = PortWriterEntry.new(port, lifetime_seconds)
                @mutex.synchronize do
                    @writers[name_service+name+port_name] = entry
                end
                #puts "add writer size: #{@writers.length}"
                entry
            end
            
            def self.getWriter(name_service, name, port_name )
                writer = nil
                @mutex.synchronize do
                    writer = @writers[name_service+name+port_name]
                end
                #puts "get writer size: #{@writers.length}"
                writer
            end
            
            #cleans the references to the writer objects
            def self.clean()
                @mutex.synchronize do
                    @writers.delete_if do |key,elem|
                        elem.expired?
                    end
                end
                #puts "writer size: #{@writers.length}"
            end
        end 
        
        class Tasks < Grape::API
            version 'v1', using: :header, vendor: :rock
            format :json

            def self.stream_async_data_to_websocket(env, data_source, count = Float::INFINITY)
                emitted_samples = 0

                # Asynchronous streaming mode
                ws = Faye::WebSocket.new(env)

                listener = data_source.on_raw_data do |sample|
                    if !ws.send(MultiJson.dump(sample.to_json_value(:special_float_values => :string)))
                        WebApp.warn "failed to send, closing connection"
                        ws.close
                        listener.stop
                    end
                    emitted_samples += 1
                    if emitted_samples == count
                        WebApp.debug "reached requested number of samples, closing connection"
                        ws.close
                        listener.stop
                    end
                end

                ws.on :close do |event|
                    listener.stop
                end

                ws
            end

            resource :tasks do
                desc "Lists all tasks that are currently reachable on the name services"
                params do
                    optional :extended_info, type: Boolean, default: false
                end
                get do
                    if params[:extended_info]
                        Hash[tasks: Orocos.name_service.each_task.map(&:to_h)]
                    else
                        Hash[task_names: Orocos.name_service.names]
                    end
                end

                helpers do
                    def task_by_name(name_service, name)
                        Orocos.name_service.get "#{name_service}/#{name}"
                    rescue Orocos::NotFound
                        error! "cannot find #{name_service}/#{name} on the registered name services", 404
                    end

                    def port_by_task_and_name(name_service, name, port_name)
                        task_by_name(name_service, name).port(port_name)
                    rescue Orocos::NotFound
                        error! "cannot find port #{port_name} on task #{name_service}/#{name}", 404
                    end
                end

                desc "Lists information about a given task"
                get ':name_service/:name' do
                    Hash[task: task_by_name(params[:name_service], params[:name]).to_h]
                end

                desc "Lists all ports of the task"
                get ':name_service/:name/ports' do
                    task = task_by_name(params[:name_service], params[:name])
                    ports = task.each_port.map(&:model)
                    Hash[ports: ports.map(&:to_h)]
                end

                desc "returns information about the given port"
                get ':name_service/:name/ports/:port_name' do
                    port = port_by_task_and_name(*params.values_at('name_service', 'name', 'port_name'))
                    Hash[port: port.model.to_h]
                end

                desc 'read a sample on the given port and returns it'
                params do
                    optional :timeout, type: Float, default: 2.0
                    optional :poll_period, type: Float, default: 0.05
                    optional :count, type: Integer
                end
                get ':name_service/:name/ports/:port_name/read' do
                    port = port_by_task_and_name(*params.values_at('name_service', 'name', 'port_name'))

                    if !port.respond_to?(:reader)
                        error! "#{port.name} is an input port, cannot read"
                    end
                    
                    if Faye::WebSocket.websocket?(env)
                        port = port.to_async.reader(init: true, pull: true)
                        count = params.fetch(:count, Float::INFINITY)
                        ws = Tasks.stream_async_data_to_websocket(env, port, count)

                        status, response = ws.rack_response
                        status status
                        response
                        
                    else # Direct polling mode
                        count = params.fetch(:count, 1)
                        reader = port.reader(init: true, pull: true)
                        result = Array.new
                        (params[:timeout] / params[:poll_period]).ceil.times do
                            while sample = reader.raw_read_new
                                result << Hash[:value => sample.to_json_value(:special_float_values => :string)]
                                if result.size == count
                                    return result
                                end
                            end
                            sleep params[:poll_period]
                        end
                        error! "did not get any sample from #{params[:name]}.#{params[:port_name]} in #{params[:timeout]} seconds", 408
                    end
                end
                
                desc "write a value to a port"
                params do
                    optional :timeout, type: Integer, default: 30
                end
                post ':name_service/:name/ports/:port_name/write' do
                    writer = PortWriters::getWriter(*params.values_at('name_service', 'name', 'port_name'))
                    if writer == nil
                        port = port_by_task_and_name(*params.values_at('name_service', 'name', 'port_name')).to_async
                        if !port.respond_to?(:writer)
                                error! "#{port.name} is an output port, cannot write" , 403
                        end 
                        writer = PortWriters::addWriter(port, *params.values_at('name_service', 'name', 'port_name'),params[:timeout])
                    end

                    begin
                        obj = MultiJson.load(request.params["value"])
                    rescue MultiJson::ParseError => exception
                        error! "malformed JSON string", 415
                    end 

                    begin
                        port.writer.write(obj)
                    rescue Typelib::UnknownConversionRequested => exception
                        error! "port type mismatch", 406
                    end     
                end
            end
        end
    end
end

