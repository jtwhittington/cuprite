# frozen_string_literal: true

require "base64"
require "forwardable"
require "cuprite/browser/targets"
require "cuprite/browser/process"
require "cuprite/browser/client"
require "cuprite/browser/page"

module Capybara::Cuprite
  class Browser
    TIMEOUT = 5
    EXTENSIONS = [
      File.expand_path("browser/javascripts/index.js", __dir__)
    ].freeze

    extend Forwardable

    attr_reader :headers

    def self.start(*args)
      new(*args)
    end

    delegate subscribe: :@client
    delegate %i(window_handle window_handles switch_to_window open_new_window
                close_window find_window_handle within_window page) => :targets
    delegate %i(visit status_code body all_text property attributes attribute
                value visible? disabled? resize path network_traffic
                clear_network_traffic response_headers refresh click right_click
                double_click hover set click_coordinates drag drag_by select
                trigger scroll_to send_keys evaluate evaluate_on evaluate_async
                execute frame_url frame_title within_frame switch_to_frame
                current_url title) => :page

    attr_reader :process, :logger
    attr_writer :timeout

    def initialize(options = nil)
      @options = Hash(options)
      @logger, @timeout = @options.values_at(:logger, :timeout)
      start
    end

    def extensions
      @extensions ||= begin
        exts = @options.fetch(:extensions, [])
        (EXTENSIONS + exts).map { |p| File.read(p) }
      end
    end

    def timeout
      @timeout || TIMEOUT
    end

    def source
      command "source"
    end

    def parents(node)
      command "parents", node
    end

    def find(method, selector)
      find_all(method, selector)
    end

    def find_within(node, method, selector)
      resolved = page.command("DOM.resolveNode", nodeId: node["nodeId"])
      object_id = resolved.dig("object", "objectId")
      find_all(method, selector, { "objectId" => object_id })
    end

    def visible_text(node)
      begin
        evaluate_on(node: node, expr: "_cuprite.visibleText(this)")
      rescue BrowserError => e
        # FIXME: ObsoleteNode first arg is node, so it should be in node class
        if e.message == "No node with given id found"
          raise ObsoleteNode.new(self, e.response)
        end

        raise
      end
    end

    def delete_text(node)
      command "delete_text", node
    end

    def select_file(node, value)
      command "select_file", node, value
    end

    def render(path, _options = {})
      # check_render_options!(options)
      # options[:full] = !!options[:full]
      data = Base64.decode64(render_base64)
      File.open(path.to_s, "wb") { |f| f.write(data) }
    end

    def render_base64(format = "png", _options = {})
      # check_render_options!(options)
      # options[:full] = !!options[:full]
      page.command("Page.captureScreenshot", format: format)["data"]
    end

    def set_zoom_factor(zoom_factor)
      command "set_zoom_factor", zoom_factor
    end

    def set_paper_size(size)
      command "set_paper_size", size
    end

    def set_proxy(ip, port, type, user, password)
      args = [ip, port, type]
      args << user if user
      args << password if password
      command("set_proxy", *args)
    end

    def headers=(headers)
      @headers = {}
      add_headers(headers)
    end

    def add_headers(headers, permanent: true)
      if headers["Referer"]
        page.referrer = headers["Referer"]
        headers.delete("Referer") unless permanent
      end

      @headers.merge!(headers)
      user_agent = @headers["User-Agent"]
      accept_language = @headers["Accept-Language"]

      set_overrides(user_agent: user_agent, accept_language: accept_language)
      page.command("Network.setExtraHTTPHeaders", headers: @headers)
    end

    def add_header(header, permanent: true)
      add_headers(header, permanent: permanent)
    end

    def set_overrides(user_agent: nil, accept_language: nil, platform: nil)
      options = Hash.new
      options[:userAgent] = user_agent if user_agent
      options[:acceptLanguage] = accept_language if accept_language
      options[:platform] if platform

      page.command("Network.setUserAgentOverride", **options) if !options.empty?
    end

    def cookies
      cookies = page.command("Network.getAllCookies")["cookies"]
      cookies.map { |c| [c["name"], Cookie.new(c)] }.to_h
    end

    def set_cookie(cookie)
      page.command("Network.setCookie", **cookie)
    end

    def remove_cookie(options)
      page.command("Network.deleteCookies", **options)
    end

    def clear_cookies
      page.command("Network.clearBrowserCookies")
    end

    def set_http_auth(user, password)
      command "set_http_auth", user, password
    end

    def page_settings=(settings)
      command "set_page_settings", settings
    end

    def url_whitelist=(whitelist)
      @url_whitelist = Array(whitelist).map { |p| { urlPattern: p } }
      page.command("Network.setRequestInterception", patterns: @url_whitelist)
    end

    def url_blacklist=(blacklist)
      @url_blacklist = Array(blacklist).map { |p| { urlPattern: "*#{p}*" } }
      page.command("Network.setRequestInterception", patterns: @url_blacklist)
    end

    def clear_memory_cache
      page.command("Network.clearBrowserCache")
    end

    def go_back
      command "go_back"
    end

    def go_forward
      command "go_forward"
    end

    def accept_confirm
      command "set_confirm_process", true
    end

    def dismiss_confirm
      command "set_confirm_process", false
    end

    def accept_prompt(response)
      command "set_prompt_response", response || false
    end

    def dismiss_prompt
      command "set_prompt_response", nil
    end

    def modal_message
      command "modal_message"
    end

    def reset
      @headers = {}
      targets.reset
    end

    def restart
      stop
      start
    end

    def stop
      @client.close
      @process.stop
      @client = @process = @targets = nil
    end

    def crash
      command("Browser.crash")
    end

    def command(*args)
      id = @client.command(*args)
      @client.wait(id: id)
    rescue DeadBrowser
      restart
      raise
    end

    def targets
      @targets ||= Targets.new(self)
    end

    private

    def start
      @headers = {}
      @process = Process.start(@options)
      @client = Client.new(self, @process.ws_url)
    end

    def check_render_options!(options)
      return if !options[:full] || !options.key?(:selector)
      warn "Ignoring :selector in #render since :full => true was given at #{caller(1..1).first}"
      options.delete(:selector)
    end

    def find_all(method, selector, within = nil)
      begin
        elements = if within
          evaluate("_cuprite.find(arguments[0], arguments[1], arguments[2])", method, selector, within)
        else
          evaluate("_cuprite.find(arguments[0], arguments[1])", method, selector)
        end

        elements.map do |element|
          # nodeType: 3, nodeName: "#text" e.g.
          target_id, node = element.values_at("target_id", "node")
          next if node["nodeType"] != 1
          within ? node : [target_id, node]
        end.compact
      rescue JavaScriptError => e
        if e.class_name == "InvalidSelector"
          raise InvalidSelector.new(e.response, method, selector)
        end
        raise
      end
    end
  end
end
