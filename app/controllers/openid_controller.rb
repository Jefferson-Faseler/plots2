require 'pathname'

require "openid"
require "openid/consumer/discovery"
require 'openid/extensions/sreg'
require 'openid/extensions/pape'
require 'openid/store/filesystem'

class OpenidController < ApplicationController
  #protect_from_forgery :except => [:index]

  include OpenidHelper
  include OpenID::Server
  layout nil

  def index

    begin
      if params['openid.mode']
        oidreq = server.decode_request(params)
      else
        oidreq = server.decode_request(Rack::Utils.parse_query(request.env['ORIGINAL_FULLPATH'].split('?')[1]))
      end
    rescue ProtocolError => e
      # invalid openid request, so just display a page with an error message
      render :text => e.to_s, :status => 500
      return
    end

    # no openid.mode was given
    unless oidreq
      render :text => "This is an OpenID server endpoint."
      return
    end

    if current_user.nil? && !params['openid.mode']
      session[:openid_return_to] = request.env['ORIGINAL_FULLPATH']
      flash[:warning] = "Please log in first."
      redirect_to "/login"
      return
    else

      if oidreq

        requested_username = ''
        if request.env['ORIGINAL_FULLPATH'] && request.env['ORIGINAL_FULLPATH'].split('?')[1]
          request.env['ORIGINAL_FULLPATH'].split('?')[1].split('&').each do |param|
            requested_username = param.split('=')[1].split('%2F').last if param.split('=')[0] == "openid.claimed_id"
          end
        end

        if current_user && requested_username.downcase != current_user.username.downcase
            flash[:error] = "You are requesting access to an account that's not yours. Please <a href='/logout'>log out</a> and use the correct account, or <a href='"+oidreq.trust_root+"'>try to login with the correct username</a>"
            redirect_to "/dashboard"
        else
          oidresp = nil
  
          if oidreq.kind_of?(CheckIDRequest)
  
            identity = oidreq.identity
  
            if oidreq.id_select
              if oidreq.immediate
                oidresp = oidreq.answer(false)
              elsif session[:username]
                # The user hasn't logged in.
                # show_decision_page(oidreq) # this doesnt make sense... it was in the example though
                session[:openid_return_to] = request.env['ORIGINAL_FULLPATH']
                redirect_to "/login"
              else
                # Else, set the identity to the one the user is using.
                identity = url_for_user
              end
    
            end
  
            if oidresp
              nil
            elsif self.is_authorized(identity, oidreq.trust_root)
              oidresp = oidreq.answer(true, nil, identity)
           
              # add the sreg response if requested
              add_sreg(oidreq, oidresp)
              # ditto pape
              add_pape(oidreq, oidresp)
           
            elsif oidreq.immediate
              server_url = url_for :action => 'index'
              oidresp = oidreq.answer(false, server_url)
           
            else
              show_decision_page(oidreq)
              return
            end
  
          else
            oidresp = server.handle_request(oidreq)
          end
    
          self.render_response(oidresp)
        end
      else
        session[:openid_return_to] = request.env['ORIGINAL_FULLPATH']
        redirect_to "/login"
      end
    end
  end

  def resume
    if session[:openid_return_to] # for openid login, redirects back to openid auth process
      return_to = session[:openid_return_to]
      session[:openid_return_to] = nil
      session[:openid_requester] = nil
      redirect_to return_to
    end
  end

  def show_decision_page(oidreq, message="Do you trust this site with your identity?")
    session[:last_oidreq] = oidreq
    @oidreq = oidreq

    if message
      flash[:notice] = message
    end

    render :template => 'openid/decide'
  end

  def user_page
    # Yadis content-negotiation: we want to return the xrds if asked for.
    accept = request.env['HTTP_ACCEPT']

    # This is not technically correct, and should eventually be updated
    # to do real Accept header parsing and logic.  Though I expect it will work
    # 99% of the time.
    if accept and accept.include?('application/xrds+xml')
      user_xrds
      return
    end

    # content negotiation failed, so just render the user page
    xrds_url = url_for(:controller=>'user',:action=>params[:username])+'/xrds'
    identity_page = <<EOS
<html><head>
<meta http-equiv="X-XRDS-Location" content="#{xrds_url}" />
<link rel="openid.server" href="#{url_for :action => 'index'}" />
</head><body><p>OpenID identity page for #{params[:username]}</p>
</body></html>
EOS

    # Also add the Yadis location header, so that they don't have
    # to parse the html unless absolutely necessary.
    response.headers['X-XRDS-Location'] = xrds_url
    render :text => identity_page
  end

  def user_xrds
    types = [
             OpenID::OPENID_2_0_TYPE,
             OpenID::OPENID_1_0_TYPE,
             OpenID::SREG_URI,
            ]

    render_xrds(types)
  end

  def idp_xrds
    types = [
             OpenID::OPENID_IDP_2_0_TYPE,
            ]

    render_xrds(types)
  end

  def decision
    oidreq = session[:last_oidreq]
    session[:last_oidreq] = nil

    if params[:yes].nil?
      redirect_to oidreq.cancel_url
      return
    else
      id_to_send = params[:id_to_send]

      identity = oidreq.identity
      if oidreq.id_select
        if id_to_send and id_to_send != ""
          session[:username] = id_to_send
          session[:approvals] = []
          identity = url_for_user
        else
          msg = "You must enter a username to in order to send " +
            "an identifier to the Relying Party."
          show_decision_page(oidreq, msg)
          return
        end
      else
        session[:username] = current_user.username
      end

      if session[:approvals]
        session[:approvals] << oidreq.trust_root
      else
        session[:approvals] = [oidreq.trust_root]
      end
      oidresp = oidreq.answer(true, nil, identity)
      add_sreg(oidreq, oidresp)
      add_pape(oidreq, oidresp)
      return self.render_response(oidresp)
    end
  end

  protected

  def server
    if @server.nil?
      server_url = url_for :action => 'index', :only_path => false
      dir = Pathname.new(request.host).join('db').join('openid-store')
      store = OpenID::Store::Filesystem.new(dir)
      @server = Server.new(store, server_url)
    end
    return @server
  end

  def approved(trust_root)
    return false if session[:approvals].nil?
    return session[:approvals].member?(trust_root)
  end

  def is_authorized(identity_url, trust_root)
    return (session[:username] and (identity_url == url_for_user) and self.approved(trust_root))
  end

  def render_xrds(types)
    type_str = ""

    types.each { |uri|
      type_str += "<Type>#{uri}</Type>\n      "
    }

    yadis = <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<xrds:XRDS
    xmlns:xrds="xri://$xrds"
    xmlns="xri://$xrd*($v*2.0)">
  <XRD>
    <Service priority="0">
      #{type_str}
      <URI>#{url_for(:controller => 'openid', :only_path => false)}</URI>
    </Service>
  </XRD>
</xrds:XRDS>
EOS

    response.headers['content-type'] = 'application/xrds+xml'
    render :text => yadis
  end

  def add_sreg(oidreq, oidresp)
    # check for Simple Registration arguments and respond
    sregreq = OpenID::SReg::Request.from_openid_request(oidreq)

    return if sregreq.nil?
    # In a real application, this data would be user-specific,
    # and the user should be asked for permission to release
    # it.
    sreg_data = {
      'nickname' => current_user.username, #session[:username],
      'email' => current_user.email
    }

    sregresp = OpenID::SReg::Response.extract_response(sregreq, sreg_data)
    oidresp.add_extension(sregresp)
  end

  def add_pape(oidreq, oidresp)
    papereq = OpenID::PAPE::Request.from_openid_request(oidreq)
    return if papereq.nil?
    paperesp = OpenID::PAPE::Response.new
    paperesp.nist_auth_level = 0 # we don't even do auth at all!
    oidresp.add_extension(paperesp)
  end

  def render_response(oidresp)
    if oidresp.needs_signing
      signed_response = server.signatory.sign(oidresp)
    end
    web_response = server.encode_response(oidresp)
    case web_response.code
    when HTTP_OK
      render :text => web_response.body, :status => 200

    when HTTP_REDIRECT
      redirect_to web_response.headers['location']

    else
      render :text => web_response.body, :status => 400
    end
  end


end
