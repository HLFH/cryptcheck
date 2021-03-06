$:.unshift File.expand_path File.join File.dirname(__FILE__), '../lib'
require 'rubygems'
require 'bundler/setup'
Bundler.require :default, :development
require 'cryptcheck'
require 'faketime'
Dir['./spec/**/support/**/*.rb'].sort.each { |f| require f }

require 'simplecov'
SimpleCov.start do
	add_filter 'spec/'
end

CryptCheck::Logger.level = ENV['LOG'] || :none

module Helpers
	DEFAULT_METHODS  = %i(TLSv1_2)
	DEFAULT_CIPHERS  = %i(ECDHE-ECDSA-AES128-GCM-SHA256)
	DEFAULT_CURVES   = %i(prime256v1)
	DEFAULT_DH       = [:rsa, 4096]
	DEFAULT_MATERIAL = [[:ecdsa, :prime256v1]]
	DEFAULT_CHAIN    = %w(intermediate ca)
	DEFAULT_HOST     = 'localhost'
	DEFAULT_IPv4     = '127.0.0.1'
	DEFAULT_IPv6     = '::1'
	DEFAULT_PORT     = 15000

	def key(type, name=nil)
		name = if name
				   "#{type}-#{name}"
			   else
				   type
			   end
		OpenSSL::PKey.read File.read "spec/resources/#{name}.pem"
	end

	def cert(type, name=nil)
		name = if name
				   "#{type}-#{name}"
			   else
				   type
			   end
		OpenSSL::X509::Certificate.new File.read "spec/resources/#{name}.crt"
	end

	def chain(chain)
		chain.collect { |f| self.cert f }
	end

	def dh(name)
		OpenSSL::PKey::DH.new File.read "spec/resources/dh-#{name}.pem"
	end

	def serv(server, process)
		IO.pipe do |stop_pipe_r, stop_pipe_w|
			threads = []

			mutex   = Mutex.new
			started = ConditionVariable.new

			threads << Thread.start do
				mutex.synchronize { started.signal }

				loop do
					readable, = IO.select [server, stop_pipe_r]
					break if readable.include? stop_pipe_r

					begin
						socket = server.accept
						begin
							process.call socket if process
						ensure
							socket.close
						end
					rescue
					end
				end
				server.close
			end

			mutex.synchronize { started.wait mutex }
			begin
				yield if block_given?
			ensure
				stop_pipe_w.close
				threads.each &:join
			end
		end
	end

	def context(certs, keys, chain=[],
				methods: DEFAULT_METHODS, ciphers: DEFAULT_CIPHERS,
				dh:, curves: DEFAULT_CURVES, server_preference: true)
		# Can't find a way to support SSLv2 with others
		context         = if methods == :SSLv2
							  OpenSSL::SSL::SSLContext.new :SSLv2
						  else
							  context         = OpenSSL::SSL::SSLContext.new
							  context.options |= OpenSSL::SSL::OP_NO_SSLv2 unless methods.include? :SSLv2
							  context.options |= OpenSSL::SSL::OP_NO_SSLv3 unless methods.include? :SSLv3
							  context.options |= OpenSSL::SSL::OP_NO_TLSv1 unless methods.include? :TLSv1
							  context.options |= OpenSSL::SSL::OP_NO_TLSv1_1 unless methods.include? :TLSv1_1
							  context.options |= OpenSSL::SSL::OP_NO_TLSv1_2 unless methods.include? :TLSv1_2
							  context
						  end
		context.options |= OpenSSL::SSL::OP_CIPHER_SERVER_PREFERENCE if server_preference

		context.certs            = certs
		context.keys             = keys
		context.extra_chain_cert = chain unless chain.empty?

		context.ciphers = ciphers.join ':'
		if methods != :SSLv2
			context.tmp_dh_callback = proc { dh } if dh
			context.ecdh_curves     = curves.join ':' if curves
		end

		context
	end

	default_parameters       = {
			methods:           %i(TLSv1_2),
			chain:             %w(intermediate ca),
			curves:            %i(prime256v1),
			server_preference: true
	}.freeze
	default_ecdsa_parameters = default_parameters.merge({
																material: [[:ecdsa, :prime256v1]],
																ciphers:  %i(ECDHE-ECDSA-AES128-SHA),
																curves:   %i(prime256v1)
														}).freeze
	default_rsa_parameters   = default_parameters.merge({
																material: [[:rsa, 1024]],
																ciphers:  %i(ECDHE-RSA-AES128-SHA),
																curves:   %i(prime256v1),
																dh:       1024
														}).freeze
	default_mixed_parameters = default_parameters.merge({
																material: [[:ecdsa, :prime256v1], [:rsa, 1024]],
																ciphers:  %i(ECDHE-ECDSA-AES128-SHA ECDHE-RSA-AES128-SHA),
																curves:   %i(prime256v1),
																dh:       1024
														}).freeze
	default_sslv2_parameters = default_parameters.merge({
																methods:  :SSLv2,
																material: [[:rsa, 1024]],
																ciphers:  %i(RC4-MD5),
																chain:    []
														}).freeze
	DEFAULT_PARAMETERS       = { ecdsa: default_ecdsa_parameters.freeze,
								 rsa:   default_rsa_parameters.freeze,
								 mixed: default_mixed_parameters.freeze,
								 sslv2: default_sslv2_parameters.freeze }.freeze

	def do_in_serv(type=:ecdsa, **kargs)
		params = DEFAULT_PARAMETERS[type].dup
		host, port = Helpers::DEFAULT_HOST, Helpers::DEFAULT_PORT
		params.merge!({ host: host, port: port })
		params.merge!(kargs) if kargs
		tls_serv **params do
			yield host, port if block_given?
		end
	end

	def tls_serv(host: DEFAULT_HOST, port: DEFAULT_PORT,
				 material: DEFAULT_MATERIAL, chain: DEFAULT_CHAIN,
				 methods: DEFAULT_METHODS, ciphers: DEFAULT_CIPHERS,
				 dh: nil, curves: DEFAULT_CURVES, server_preference: true,
				 process: nil, &block)
		keys  = material.collect { |m| key *m }
		certs = material.collect { |m| cert *m }
		chain = chain.collect { |c| cert c }
		dh    = dh dh if dh

		context    = context certs, keys, chain,
							 methods:           methods, ciphers: ciphers,
							 dh:                dh, curves: curves,
							 server_preference: server_preference
		tcp_server = TCPServer.new host, port
		tls_server = OpenSSL::SSL::SSLServer.new tcp_server, context
		begin
			serv tls_server, process, &block
		ensure
			tls_server.close
			tcp_server.close
		end
	end

	def plain_serv(host=DEFAULT_HOST, port=DEFAULT_PORT, process: nil, &block)
		tcp_server = TCPServer.new host, port
		begin
			serv tcp_server, process, &block
		ensure
			tcp_server.close
		end
	end

	def starttls_serv(key: DEFAULT_KEY, domain: DEFAULT_HOST, # Key & certificate
					  version: DEFAULT_METHOD, ciphers: DEFAULT_CIPHERS, # TLS version and ciphers
					  dh: DEFAULT_DH_SIZE, ecdh: DEFAULT_ECC_CURVE, # DHE & ECDHE
					  host: DEFAULT_HOST, port: DEFAULT_PORT, # Binding
					  plain_process: nil, process: nil, &block)
		context                      = context(key: key, domain: domain, version: version, ciphers: ciphers, dh: dh, ecdh: ecdh)
		tcp_server                   = TCPServer.new host, port
		tls_server                   = OpenSSL::SSL::SSLServer.new tcp_server, context
		tls_server.start_immediately = false

		internal_process = proc do |socket|
			accept = false
			accept = plain_process.call socket if plain_process
			if accept
				tls_socket = socket.accept
				begin
					process.call tls_socket if process
				ensure
					socket.close
				end
			end
		end

		begin
			serv tls_server, internal_process, &block
		ensure
			tls_server.close
			tcp_server.close
		end
	end

	def server(servers, host, ip, port)
		servers[[host, ip, port]]
	end

	def expect_grade(servers, host, ip, port, family)
		server = server servers, host, ip, port
		expect(server).to be_a CryptCheck::Tls::Server
		expect(server.hostname).to eq host
		expect(server.ip).to eq ip
		expect(server.port).to eq port
		expect(server.family).to eq case family
										when :ipv4
											Socket::AF_INET
										when :ipv6
											Socket::AF_INET6
									end
	end

	def expect_grade_error(servers, host, ip, port, error)
		server = servers[[host, ip, port]]
		expect(server).to be_a CryptCheck::Tls::AnalysisFailure
		expect(server.to_s).to eq error
	end

	def expect_error(error, type, message)
		expect(error).to be_a type
		expect(error.message).to eq message
	end
end

RSpec.configure do |c|
	c.include Helpers
end
