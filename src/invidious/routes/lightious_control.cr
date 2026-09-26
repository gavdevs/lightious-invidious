{% skip_file if flag?(:api_only) %}

module Invidious::Routes::LightiousControl
  extend self

  CSRF_SCOPE              = {"POST:lightious/*"}
  MODES                   = {"library", "focused"}
  POLICIES                = {"listen_only", "watch_and_listen"}
  SEARCH_TYPES            = {"all", "video", "channel"}
  MAX_SEARCH_QUERY_BYTES  = 256
  MAX_LIBRARY_SELECTIONS  = 100
  MAX_BULK_SELECTIONS     = 250
  MAX_PLAYLIST_NAME_BYTES = 100
  MAX_PLAYLIST_ITEMS      = 250
  CHANNEL_TABS            = {"all", "videos", "streams"}

  def dashboard(env)
    locale = env.get("preferences").as(Preferences).locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, "/lightious") unless user && sid

    user = user.as(User)
    sid = sid.as(String)
    profile = Invidious::Database::Lightious.ensure_profile(
      user.email,
      Random::Secure.hex(16),
      Time.utc,
    )
    devices = Invidious::Database::Lightious.devices_for_account(user.email)
    csrf_token = generate_response(sid, CSRF_SCOPE, HMAC_KEY)
    notice = notice_text(env.params.query["notice"]?)
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/dashboard", "lightious/template", navbar_search: false
  end

  def search(env)
    location = "/lightious/library"
    if query = env.request.query
      location += "?#{query}"
    end
    env.redirect location
  end

  def library(env)
    preferences = env.get("preferences").as(Preferences)
    locale = preferences.locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, env.request.resource) unless user && sid

    user = user.as(User)
    profile = Invidious::Database::Lightious.ensure_profile(
      user.email,
      Random::Secure.hex(16),
      Time.utc,
    )
    items = Invidious::Database::Lightious.items_for_profile(profile.id)
    channels = Invidious::Database::Lightious.channels_for_profile(profile.id)
    playlists = Invidious::Database::Lightious.playlists_for_profile(profile.id)
    playlist_item_counts = {} of String => Int32
    playlists.each do |playlist|
      playlist_item_counts[playlist.id] = Invidious::Database::Lightious
        .items_for_playlist(playlist.id, profile.id)
        .size
    end

    search_query = env.params.query["q"]?.to_s.strip
    search_type = normalized_search_type(env.params.query["type"]?)
    search_page = normalized_page(env.params.query["page"]?)
    search_results = [] of SearchItem
    search_videos = [] of SearchVideo
    search_channels = [] of SearchChannel
    search_error : String? = nil
    show_next_page = false

    if search_query.bytesize > MAX_SEARCH_QUERY_BYTES
      search_error = "That search is too long."
    elsif !search_query.empty?
      begin
        raw_results = run_search(search_query, search_type, search_page, preferences.region)
        show_next_page = raw_results.size >= 20
        raw_results.each do |item|
          case item
          when SearchVideo
            search_results << item
            search_videos << item
          when SearchChannel
            search_results << item
            search_channels << item
          end
        end
      rescue ex
        search_error = ex.message || "Search is temporarily unavailable."
      end
    end

    csrf_token = generate_response(sid.as(String), CSRF_SCOPE, HMAC_KEY)
    notice = notice_text(env.params.query["notice"]?)
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/search", "lightious/template", navbar_search: false
  end

  def add_library_selections(env)
    user = authenticated_user(env, "/lightious/library")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    search_query = env.params.body["q"]?.to_s.strip
    search_type = normalized_search_type(env.params.body["type"]?)
    search_page = normalized_page(env.params.body["page"]?)
    return error_template(400, "Enter a search query first.") if search_query.empty?
    if search_query.bytesize > MAX_SEARCH_QUERY_BYTES
      return error_template(400, "That search is too long.")
    end

    raw_selections = if single = env.params.body["single_selection"]?
                       [single]
                     else
                       env.params.body.fetch_all("selection[]")
                     end
    raw_selections = raw_selections.uniq
    if raw_selections.empty?
      redirect_query = URI::Params.encode({
        q:      search_query,
        type:   search_type,
        page:   search_page.to_s,
        notice: "selection-required",
      })
      env.redirect "/lightious/library?#{redirect_query}#search-results"
      return
    end
    if raw_selections.size > MAX_LIBRARY_SELECTIONS
      return error_template(400, "Choose no more than #{MAX_LIBRARY_SELECTIONS} results at once.")
    end

    selections = [] of Invidious::Lightious::LibrarySelection::Entry
    raw_selections.each do |value|
      selection = Invidious::Lightious::LibrarySelection.parse(value)
      return error_template(400, "One of the selected results is invalid.") unless selection
      selections << selection
    end

    selection_kind = env.params.body["selection_kind"]?.to_s
    expected_kind = case selection_kind
                    when "video"   then Invidious::Lightious::LibrarySelection::Kind::Video
                    when "channel" then Invidious::Lightious::LibrarySelection::Kind::Channel
                    else                return error_template(400, "Choose videos or channels to add.")
                    end
    unless selections.all? { |selection| selection.kind == expected_kind }
      return error_template(400, "Videos and channels must be added separately.")
    end

    preferences = env.get("preferences").as(Preferences)
    begin
      raw_results = run_search(search_query, search_type, search_page, preferences.region)
    rescue ex
      return error_template(502, ex)
    end

    available = {} of String => SearchItem
    raw_results.each do |item|
      case item
      when SearchVideo
        available["video:#{item.id}"] = item
      when SearchChannel
        available["channel:#{item.ucid}"] = item
      end
    end
    unless selections.all? { |selection| available.has_key?(selection.key) }
      return error_template(409, "The search results changed. Search again and retry your selection.")
    end

    profile = Invidious::Database::Lightious.ensure_profile(user.email, Random::Secure.hex(16), Time.utc)
    saved_count = if expected_kind.video?
                    action = Invidious::Lightious::LibraryAction.parse_video(env.params.body["library_action"]?)
                    return error_template(400, "Choose where the selected videos should go.") unless action
                    playlist_id = validated_playlist_id(profile.id, env.params.body["playlist_id"]?) if action.destination.includes_playlist?
                    if action.destination.includes_playlist? && !playlist_id
                      return redirect_library_search(env, search_query, search_type, search_page, "playlist-required")
                    end

                    inputs = selections.map do |selection|
                      item = available[selection.key].as(SearchVideo)
                      Invidious::Database::Lightious::ItemInput.new(
                        item_id: Random::Secure.hex(16),
                        video_id: item.id,
                        title: item.title,
                        author: item.author,
                        author_ucid: item.ucid,
                        length_seconds: item.length_seconds.to_i64,
                        thumbnail_url: "/vi/#{item.id}/mqdefault.jpg",
                        playback_policy: action.playback_policy,
                        is_short: Invidious::Lightious::ShortsPolicy.short?(item),
                      )
                    end
                    result = Invidious::Database::Lightious.save_videos_destination(
                      user.email,
                      inputs,
                      database_destination(action.destination),
                      Time.utc,
                      playlist_id,
                    )
                    result.try(&.items_saved) || 0
                  else
                    policy = Invidious::Lightious::LibraryAction.parse_channel(env.params.body["library_action"]?)
                    return error_template(400, "Choose audio or video for the selected channels.") unless policy
                    selections.count do |selection|
                      item = available[selection.key].as(SearchChannel)
                      Invidious::Database::Lightious.upsert_channel(
                        account: user.email,
                        channel_id: Random::Secure.hex(16),
                        ucid: item.ucid,
                        title: item.author,
                        thumbnail_url: channel_thumbnail_url(item),
                        playback_policy: policy,
                        now: Time.utc,
                      )
                    end
                  end

    return error_template(500, "Could not add the selected results.") if saved_count == 0

    redirect_library_search(env, search_query, search_type, search_page, "library")
  end

  def playlists_page(env)
    locale = env.get("preferences").as(Preferences).locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, "/lightious/playlists") unless user && sid

    user = user.as(User)
    profile = Invidious::Database::Lightious.ensure_profile(
      user.email,
      Random::Secure.hex(16),
      Time.utc,
    )
    playlists = Invidious::Database::Lightious.playlists_for_profile(profile.id)
    playlist_item_counts = {} of String => Int32
    playlists.each do |playlist|
      playlist_item_counts[playlist.id] = Invidious::Database::Lightious
        .items_for_playlist(playlist.id, profile.id).size
    end
    total_playlist_items = playlist_item_counts.values.sum
    csrf_token = generate_response(sid.as(String), CSRF_SCOPE, HMAC_KEY)
    notice = notice_text(env.params.query["notice"]?)
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/playlists", "lightious/template", navbar_search: false
  end

  def playlist_page(env)
    preferences = env.get("preferences").as(Preferences)
    locale = preferences.locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, env.request.resource) unless user && sid

    user = user.as(User)
    profile = Invidious::Database::Lightious.ensure_profile(
      user.email,
      Random::Secure.hex(16),
      Time.utc,
    )
    playlist = Invidious::Database::Lightious.playlists_for_profile(profile.id)
      .find { |candidate| candidate.id == env.params.url["id"] }
    return error_template(404, "Playlist not found.") unless playlist

    playlist_items = Invidious::Database::Lightious.items_for_playlist(playlist.id, profile.id)
    search_query = env.params.query["q"]?.to_s.strip
    search_page = normalized_page(env.params.query["page"]?)
    search_videos = [] of SearchVideo
    search_error : String? = nil
    show_next_page = false
    if search_query.bytesize > MAX_SEARCH_QUERY_BYTES
      search_error = "That search is too long."
    elsif !search_query.empty?
      begin
        raw_results = run_search(search_query, "video", search_page, preferences.region)
        show_next_page = raw_results.size >= 20
        raw_results.each { |item| search_videos << item if item.is_a?(SearchVideo) }
      rescue ex
        search_error = ex.message || "Search is temporarily unavailable."
      end
    end

    csrf_token = generate_response(sid.as(String), CSRF_SCOPE, HMAC_KEY)
    notice = notice_text(env.params.query["notice"]?)
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/playlist", "lightious/template", navbar_search: false
  end

  def create_playlist(env)
    user = authenticated_user(env, "/lightious/playlists")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    name = normalized_playlist_name(env.params.body["name"]?)
    return error_template(400, "Enter a playlist name.") unless name

    Invidious::Database::Lightious.ensure_profile(user.email, Random::Secure.hex(16), Time.utc)
    playlist_id = Random::Secure.hex(16)
    created = Invidious::Database::Lightious.create_playlist(
      user.email,
      playlist_id,
      name,
      Time.utc,
    )
    return error_template(500, "Could not create the playlist.") unless created

    env.redirect "/lightious/playlists/#{playlist_id}?notice=playlist-created"
  end

  def rename_playlist(env)
    user = authenticated_user(env, "/lightious/playlists")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    name = normalized_playlist_name(env.params.body["name"]?)
    return error_template(400, "Enter a playlist name.") unless name

    profile = Invidious::Database::Lightious.profile_for_account(user.email)
    return error_template(404, "Lightious profile not found.") unless profile
    playlist = Invidious::Database::Lightious.playlists_for_profile(profile.id)
      .find { |candidate| candidate.id == env.params.url["id"] }
    return error_template(404, "Playlist not found.") unless playlist

    if playlist.name != name
      renamed = Invidious::Database::Lightious.rename_playlist(
        user.email,
        playlist.id,
        name,
        Time.utc,
      )
      return error_template(500, "Could not rename the playlist.") unless renamed
    end

    env.redirect "/lightious/playlists/#{playlist.id}?notice=playlist-renamed#playlist-settings"
  end

  def add_playlist_search_selections(env)
    referer = "/lightious/playlists/#{env.params.url["id"]}"
    user = authenticated_user(env, referer)
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    profile = Invidious::Database::Lightious.profile_for_account(user.email)
    return error_template(404, "Lightious profile not found.") unless profile
    playlist_id = validated_playlist_id(profile.id, env.params.url["id"])
    return error_template(404, "Playlist not found.") unless playlist_id

    search_query = env.params.body["q"]?.to_s.strip
    search_page = normalized_page(env.params.body["page"]?)
    return error_template(400, "Enter a search query first.") if search_query.empty?
    return error_template(400, "That search is too long.") if search_query.bytesize > MAX_SEARCH_QUERY_BYTES

    action = Invidious::Lightious::LibraryAction.parse_video(env.params.body["library_action"]?)
    unless action && action.destination.includes_playlist?
      return error_template(400, "Choose playlist-only or playlist-and-library access.")
    end

    selections = parsed_video_selections(env.params.body.fetch_all("selection[]"))
    return redirect_playlist_search(env, playlist_id, search_query, search_page, "selection-required") if selections.empty?
    return error_template(400, "Choose no more than #{MAX_LIBRARY_SELECTIONS} videos at once.") if selections.size > MAX_LIBRARY_SELECTIONS

    preferences = env.get("preferences").as(Preferences)
    begin
      raw_results = run_search(search_query, "video", search_page, preferences.region)
    rescue ex
      return error_template(502, ex)
    end
    available = raw_results.select(SearchVideo).to_h { |item| {item.id, item} }
    unless selections.all? { |selection| available.has_key?(selection.id) }
      return error_template(409, "The search results changed. Search again and retry your selection.")
    end

    inputs = selections.map { |selection| item_input(available[selection.id], action.playback_policy) }
    result = Invidious::Database::Lightious.save_videos_destination(
      user.email,
      inputs,
      database_destination(action.destination),
      Time.utc,
      playlist_id,
    )
    return error_template(500, "Could not add the selected videos.") unless result

    redirect_playlist_search(env, playlist_id, search_query, search_page, "playlist-items")
  end

  def remove_playlist_items(env)
    referer = "/lightious/playlists/#{env.params.url["id"]}"
    user = authenticated_user(env, referer)
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    profile = Invidious::Database::Lightious.profile_for_account(user.email)
    return error_template(404, "Lightious profile not found.") unless profile
    playlist_id = validated_playlist_id(profile.id, env.params.url["id"])
    return error_template(404, "Playlist not found.") unless playlist_id

    requested_ids = env.params.body.fetch_all("item_ids[]").uniq
    current_ids = Invidious::Database::Lightious.items_for_playlist(playlist_id, profile.id).map(&.id)
    selected_ids = validated_owned_ids(requested_ids, current_ids)
    return error_template(400, "Choose at least one video from this playlist.") unless selected_ids

    selected_ids.each do |item_id|
      Invidious::Database::Lightious.remove_playlist_item(user.email, playlist_id, item_id, Time.utc)
    end
    env.redirect "/lightious/playlists/#{playlist_id}?notice=playlist-items#playlist-videos"
  end

  def delete_playlist(env)
    user = authenticated_user(env, "/lightious/playlists")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    deleted = Invidious::Database::Lightious.delete_playlist(
      user.email,
      env.params.url["id"],
      Time.utc,
    )
    return error_template(404, "Playlist not found.") unless deleted

    env.redirect "/lightious/playlists?notice=playlist-deleted"
  end

  def bulk_videos(env)
    user = authenticated_user(env, "/lightious/library#videos")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    profile = Invidious::Database::Lightious.profile_for_account(user.email)
    return error_template(404, "Lightious profile not found.") unless profile
    available_ids = Invidious::Database::Lightious.visible_items_for_profile(profile.id).map(&.id)
    selected_ids = validated_owned_ids(env.params.body.fetch_all("item_ids[]"), available_ids)
    return error_template(400, "Choose at least one video to update.") unless selected_ids

    notice = "video-bulk"
    case env.params.body["bulk_action"]?.to_s
    when "audio", "video"
      policy = env.params.body["bulk_action"] == "audio" ? "listen_only" : "watch_and_listen"
      Invidious::Database::Lightious.bulk_update_item_policy(user.email, selected_ids, policy, Time.utc)
    when "playlist"
      playlist_id = validated_playlist_id(profile.id, env.params.body["playlist_id"]?)
      return error_template(400, "Choose a playlist.") unless playlist_id
      Invidious::Database::Lightious.add_playlist_items(user.email, playlist_id, selected_ids, Time.utc)
      notice = "video-playlist"
    when "remove"
      selected_ids.each { |item_id| Invidious::Database::Lightious.remove_item_from_library(user.email, item_id, Time.utc) }
      notice = "video-removed"
    else
      return error_template(400, "Choose a valid video action.")
    end

    env.redirect "/lightious/library?notice=#{notice}#videos"
  end

  def bulk_channels(env)
    user = authenticated_user(env, "/lightious/library#channels")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    profile = Invidious::Database::Lightious.profile_for_account(user.email)
    return error_template(404, "Lightious profile not found.") unless profile
    available_ids = Invidious::Database::Lightious.channels_for_profile(profile.id).map(&.id)
    selected_ids = validated_owned_ids(env.params.body.fetch_all("channel_ids[]"), available_ids)
    return error_template(400, "Choose at least one channel to update.") unless selected_ids

    case env.params.body["bulk_action"]?.to_s
    when "audio", "video"
      policy = env.params.body["bulk_action"] == "audio" ? "listen_only" : "watch_and_listen"
      Invidious::Database::Lightious.bulk_update_channel_policy(user.email, selected_ids, policy, Time.utc)
      notice = "channel-bulk"
    when "remove"
      selected_ids.each { |channel_id| Invidious::Database::Lightious.delete_channel(user.email, channel_id, Time.utc) }
      notice = "channel-removed"
    else
      return error_template(400, "Choose a valid channel action.")
    end

    env.redirect "/lightious/library?notice=#{notice}#channels"
  end

  def channel_page(env)
    preferences = env.get("preferences").as(Preferences)
    locale = preferences.locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, env.request.resource) unless user && sid

    ucid = env.params.url["ucid"]
    return error_template(404, "Channel not found.") unless valid_channel_id?(ucid)
    begin
      channel = get_about_info(ucid)
    rescue ex : ChannelRedirect
      return env.redirect "/lightious/channels/#{URI.encode_www_form(ex.channel_id)}"
    rescue ex : NotFoundException
      return error_template(404, ex)
    rescue ex
      return error_template(502, ex)
    end

    user = user.as(User)
    profile = Invidious::Database::Lightious.ensure_profile(user.email, Random::Secure.hex(16), Time.utc)
    added_channel = Invidious::Database::Lightious.channels_for_profile(profile.id)
      .find { |candidate| candidate.ucid == channel.ucid }
    playlists = Invidious::Database::Lightious.playlists_for_profile(profile.id)
    channel_search_query = env.params.query["q"]?.to_s.strip
    channel_search_page = normalized_page(env.params.query["page"]?)
    channel_tab = normalized_channel_tab(env.params.query["tab"]?, channel)
    channel_results = [] of SearchVideo
    channel_result_kinds = {} of String => String
    channel_error : String? = nil
    show_next_page = false

    if channel_search_query.bytesize > MAX_SEARCH_QUERY_BYTES
      channel_error = "That search is too long."
    else
      begin
        if channel_search_query.empty?
          channel_results, channel_result_kinds = run_channel_browse(channel, channel_tab)
        else
          raw_results = run_channel_search(channel.ucid, channel_search_query, channel_search_page, preferences.region)
          show_next_page = raw_results.size >= 20
          raw_results.each do |item|
            next unless item.is_a?(SearchVideo)
            channel_results << item
            channel_result_kinds[item.id] = if item.badges.live_now?
                                              "Live now"
                                            elsif item.upcoming?
                                              "Upcoming"
                                            else
                                              "Video"
                                            end
          end
        end
      rescue ex
        channel_error = ex.message || "This channel is temporarily unavailable."
      end
    end

    channel_tab_label = channel_tab_title(channel_tab)
    csrf_token = generate_response(sid.as(String), CSRF_SCOPE, HMAC_KEY)
    notice = notice_text(env.params.query["notice"]?)
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/channel", "lightious/template", navbar_search: false
  end

  def add_explicit_channel(env)
    referer = "/lightious/channels/#{env.params.url["ucid"]}"
    user = authenticated_user(env, referer)
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    ucid = env.params.url["ucid"]
    return error_template(404, "Channel not found.") unless valid_channel_id?(ucid)
    policy = Invidious::Lightious::LibraryAction.parse_channel(env.params.body["library_action"]?)
    return error_template(400, "Choose audio or video for this channel.") unless policy

    begin
      channel = get_about_info(ucid)
    rescue ex : ChannelRedirect
      return env.redirect "/lightious/channels/#{URI.encode_www_form(ex.channel_id)}"
    rescue ex : NotFoundException
      return error_template(404, ex)
    rescue ex
      return error_template(502, ex)
    end

    Invidious::Database::Lightious.ensure_profile(user.email, Random::Secure.hex(16), Time.utc)
    saved = Invidious::Database::Lightious.upsert_channel(
      account: user.email,
      channel_id: Random::Secure.hex(16),
      ucid: channel.ucid,
      title: channel.author,
      thumbnail_url: channel_thumbnail_url(channel),
      playback_policy: policy,
      now: Time.utc,
    )
    return error_template(500, "Could not add this channel.") unless saved

    env.redirect "/lightious/channels/#{channel.ucid}?notice=channel-added"
  end

  def add_channel_video_selections(env)
    referer = "/lightious/channels/#{env.params.url["ucid"]}"
    user = authenticated_user(env, referer)
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    ucid = env.params.url["ucid"]
    return error_template(404, "Channel not found.") unless valid_channel_id?(ucid)
    begin
      channel = get_about_info(ucid)
    rescue ex : ChannelRedirect
      return env.redirect "/lightious/channels/#{URI.encode_www_form(ex.channel_id)}"
    rescue ex
      return error_template(502, ex)
    end

    query_text = env.params.body["q"]?.to_s.strip
    page = normalized_page(env.params.body["page"]?)
    tab = normalized_channel_tab(env.params.body["tab"]?, channel)
    return error_template(400, "That search is too long.") if query_text.bytesize > MAX_SEARCH_QUERY_BYTES
    selections = parsed_video_selections(env.params.body.fetch_all("selection[]"))
    return redirect_channel_view(env, channel.ucid, query_text, tab, page, "selection-required") if selections.empty?
    return error_template(400, "Choose no more than #{MAX_LIBRARY_SELECTIONS} videos at once.") if selections.size > MAX_LIBRARY_SELECTIONS

    preferences = env.get("preferences").as(Preferences)
    begin
      results = if query_text.empty?
                  run_channel_browse(channel, tab)[0]
                else
                  run_channel_search(channel.ucid, query_text, page, preferences.region).select(SearchVideo)
                end
    rescue ex
      return error_template(502, ex)
    end
    available = results.to_h { |item| {item.id, item} }
    unless selections.all? { |selection| available.has_key?(selection.id) }
      return error_template(409, "The channel results changed. Refresh and retry your selection.")
    end

    action = Invidious::Lightious::LibraryAction.parse_video(env.params.body["library_action"]?)
    return error_template(400, "Choose where the selected videos should go.") unless action
    profile = Invidious::Database::Lightious.ensure_profile(user.email, Random::Secure.hex(16), Time.utc)
    playlist_id = validated_playlist_id(profile.id, env.params.body["playlist_id"]?) if action.destination.includes_playlist?
    if action.destination.includes_playlist? && !playlist_id
      return redirect_channel_view(env, channel.ucid, query_text, tab, page, "playlist-required")
    end

    inputs = selections.map { |selection| item_input(available[selection.id], action.playback_policy) }
    result = Invidious::Database::Lightious.save_videos_destination(
      user.email,
      inputs,
      database_destination(action.destination),
      Time.utc,
      playlist_id,
    )
    return error_template(500, "Could not add the selected videos.") unless result

    redirect_channel_view(env, channel.ucid, query_text, tab, page, "channel-videos-added")
  end

  def pair_page(env)
    locale = env.get("preferences").as(Preferences).locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, "/lightious/pair") unless user && sid

    sid = sid.as(String)
    csrf_token = generate_response(sid, CSRF_SCOPE, HMAC_KEY)
    user_code = ""
    pending_pairing = nil
    error_message = nil
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/pair", "lightious/template", navbar_search: false
  end

  def preview_pairing(env)
    locale = env.get("preferences").as(Preferences).locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, "/lightious/pair") unless user && sid

    sid = sid.as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    user_code = env.params.body["user_code"]?.to_s
    digest = Invidious::Lightious::Pairing.user_code_digest(HMAC_KEY, user_code)
    pending_pairing = digest.try do |value|
      Invidious::Database::Lightious.pairing_for_user_code(value, Time.utc)
    end
    error_message = pending_pairing ? nil : "That pairing code is invalid or expired."
    csrf_token = generate_response(sid, CSRF_SCOPE, HMAC_KEY)
    env.response.headers["Cache-Control"] = "no-store"

    templated "lightious/pair", "lightious/template", navbar_search: false
  end

  def claim_pairing(env)
    locale = env.get("preferences").as(Preferences).locale
    user = env.get?("user")
    sid = env.get?("sid")
    return redirect_to_login(env, "/lightious/pair") unless user && sid

    user = user.as(User)
    sid = sid.as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    user_code = env.params.body["user_code"]?.to_s
    digest = Invidious::Lightious::Pairing.user_code_digest(HMAC_KEY, user_code)
    return error_template(400, "That pairing code is invalid or expired.") unless digest

    pairing = Invidious::Database::Lightious.claim_pairing(
      digest,
      user.email,
      Random::Secure.hex(16),
      Time.utc,
    )
    return error_template(409, "That pairing code is invalid, expired, or already used.") unless pairing

    env.redirect "/lightious?notice=paired"
  end

  def update_mode(env)
    user = authenticated_user(env, "/lightious")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    mode = env.params.body["mode"]?.to_s
    return error_template(400, "Choose Library or Focused mode.") unless MODES.includes?(mode)

    limit = env.params.body["channel_feed_limit"]?.try(&.to_i?)
    unless limit && limit.in?(1..Invidious::Lightious::ChannelFeed::MAX_RECENT_LIMIT)
      return error_template(400, "Choose between 1 and 5 recent videos per channel.")
    end
    hide_watched = env.params.body["hide_watched"]? == "true"

    profile = Invidious::Database::Lightious.update_experience(
      user.email, mode, limit, hide_watched, Time.utc,
    )
    return error_template(404, "Lightious profile not found.") unless profile

    env.redirect "/lightious?notice=mode"
  end

  def update_video_policy(env)
    user = authenticated_user(env, "/lightious/library")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    policy = env.params.body["playback_policy"]?.to_s
    return error_template(400, "Choose a valid playback policy.") unless POLICIES.includes?(policy)

    Invidious::Database::Lightious.update_item_policy(
      user.email,
      env.params.url["id"],
      policy,
      Time.utc,
    )
    env.redirect "/lightious/library?notice=policy#videos"
  end

  def delete_video(env)
    user = authenticated_user(env, "/lightious/library")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    Invidious::Database::Lightious.delete_item(user.email, env.params.url["id"], Time.utc)
    env.redirect "/lightious/library?notice=removed#videos"
  end

  def update_channel_policy(env)
    user = authenticated_user(env, "/lightious/library")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    policy = env.params.body["playback_policy"]?.to_s
    return error_template(400, "Choose a valid playback policy.") unless POLICIES.includes?(policy)

    Invidious::Database::Lightious.update_channel_policy(
      user.email,
      env.params.url["ucid"],
      policy,
      Time.utc,
    )
    env.redirect "/lightious/library?notice=channel-policy#channels"
  end

  def delete_channel(env)
    user = authenticated_user(env, "/lightious/library")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    Invidious::Database::Lightious.delete_channel(user.email, env.params.url["ucid"], Time.utc)
    env.redirect "/lightious/library?notice=channel-removed#channels"
  end

  def revoke_device(env)
    user = authenticated_user(env, "/lightious")
    return unless user
    sid = env.get("sid").as(String)
    if error_message = csrf_error(env, sid)
      return error_template(400, error_message)
    end

    Invidious::Database::Lightious.revoke_device(
      env.params.url["id"],
      user.email,
      Time.utc,
    )
    env.redirect "/lightious?notice=revoked"
  end

  private def authenticated_user(env, referer : String) : User?
    user = env.get?("user").try &.as(User)
    unless user && env.get?("sid")
      redirect_to_login(env, referer)
      return nil
    end
    user
  end

  private def csrf_error(env, sid : String) : String?
    validate_request(env.params.body["csrf_token"]?, sid, env.request, HMAC_KEY, nil)
    nil
  rescue ex
    ex.message || "Invalid request."
  end

  private def redirect_to_login(env, referer : String)
    env.redirect "/login?referer=#{URI.encode_www_form(referer)}"
  end

  private def normalized_search_type(value : String?) : String
    candidate = value.to_s.downcase
    SEARCH_TYPES.includes?(candidate) ? candidate : "all"
  end

  private def normalized_page(value : String?) : Int32
    page = value.try(&.to_i?) || 1
    page.clamp(1, 50)
  end

  private def validated_playlist_id(profile_id : String, value : String?) : String?
    playlist_id = value.to_s
    return nil if playlist_id.empty?

    Invidious::Database::Lightious.playlists_for_profile(profile_id)
      .find { |playlist| playlist.id == playlist_id }
      .try(&.id)
  end

  private def validated_owned_ids(requested_ids : Array(String), available_ids : Array(String)) : Array(String)?
    selected_ids = requested_ids.uniq
    return nil if selected_ids.empty? || selected_ids.size > MAX_BULK_SELECTIONS
    return nil unless selected_ids.all? { |id| available_ids.includes?(id) }

    selected_ids
  end

  private def parsed_video_selections(values : Array(String)) : Array(Invidious::Lightious::LibrarySelection::Entry)
    unique_values = values.uniq
    parsed = unique_values.compact_map { |value| Invidious::Lightious::LibrarySelection.parse(value) }
    return [] of Invidious::Lightious::LibrarySelection::Entry unless parsed.size == unique_values.size
    return [] of Invidious::Lightious::LibrarySelection::Entry unless parsed.all?(&.kind.video?)

    parsed
  end

  private def item_input(item : SearchVideo, playback_policy : String) : Invidious::Database::Lightious::ItemInput
    Invidious::Database::Lightious::ItemInput.new(
      item_id: Random::Secure.hex(16),
      video_id: item.id,
      title: item.title,
      author: item.author,
      author_ucid: item.ucid,
      length_seconds: item.length_seconds.to_i64,
      thumbnail_url: "/vi/#{item.id}/mqdefault.jpg",
      playback_policy: playback_policy,
      is_short: Invidious::Lightious::ShortsPolicy.short?(item),
    )
  end

  private def database_destination(
    destination : Invidious::Lightious::LibraryAction::Destination,
  ) : Invidious::Lightious::LibraryDestination
    case destination
    when .library?
      Invidious::Lightious::LibraryDestination::LibraryOnly
    when .playlist?
      Invidious::Lightious::LibraryDestination::PlaylistOnly
    else
      Invidious::Lightious::LibraryDestination::LibraryAndPlaylist
    end
  end

  private def redirect_library_search(env, query : String, search_type : String, page : Int32, notice : String)
    params = URI::Params.encode({q: query, type: search_type, page: page.to_s, notice: notice})
    env.redirect "/lightious/library?#{params}#search-results"
  end

  private def redirect_playlist_search(env, playlist_id : String, query : String, page : Int32, notice : String)
    params = URI::Params.encode({q: query, page: page.to_s, notice: notice})
    env.redirect "/lightious/playlists/#{playlist_id}?#{params}#find-videos"
  end

  private def redirect_channel_view(
    env,
    ucid : String,
    query : String,
    tab : String,
    page : Int32,
    notice : String,
  )
    values = {"notice" => notice}
    if query.empty?
      values["tab"] = tab
    else
      values["q"] = query
      values["page"] = page.to_s
    end
    env.redirect "/lightious/channels/#{ucid}?#{URI::Params.encode(values)}#channel-videos"
  end

  private def run_search(query_text : String, search_type : String, page : Int32, region : String?) : Array(SearchItem)
    params = HTTP::Params.new({
      "q"    => [query_text],
      "type" => [search_type],
      "page" => [page.to_s],
    })
    query = Invidious::Search::Query.new(
      params,
      Invidious::Search::Query::Type::Regular,
      region,
    )

    # Calling the regular processor directly prevents URL-shaped queries and
    # legacy smart filters from switching this companion page into navigation
    # or a user-specific search mode.
    Invidious::Lightious::ShortsPolicy.reject_from(
      Invidious::Search::Processors.regular(query)
    )
  end

  private def run_channel_search(
    ucid : String,
    query_text : String,
    page : Int32,
    region : String?,
  ) : Array(SearchItem)
    params = HTTP::Params.new({
      "q"    => [query_text],
      "page" => [page.to_s],
    })
    query = Invidious::Search::Query.new(
      params,
      Invidious::Search::Query::Type::Channel,
      region,
    )
    query.channel = ucid
    Invidious::Lightious::ShortsPolicy.reject_from(
      Invidious::Search::Processors.channel(query)
    )
  end

  private def normalized_channel_tab(value : String?, channel : AboutChannel) : String
    candidate = value.to_s.downcase
    candidate = "all" unless CHANNEL_TABS.includes?(candidate)
    return "all" if candidate == "streams" && !channel.tabs.includes?("streams")

    candidate
  end

  private def run_channel_browse(channel : AboutChannel, tab : String) : {Array(SearchVideo), Hash(String, String)}
    requested_tabs = if tab == "all"
                       ["videos"].tap do |tabs|
                         tabs << "streams" if channel.tabs.includes?("streams")
                       end
                     else
                       [tab]
                     end
    results = [] of SearchVideo
    kinds = {} of String => String
    requested_tabs.each do |requested_tab|
      raw_items, _continuation = case requested_tab
                                 when "streams"
                                   Invidious::Channel::Tabs.get_60_livestreams(channel, sort_by: "newest")
                                 else
                                   Invidious::Channel::Tabs.get_60_videos(channel, sort_by: "newest")
                                 end
      raw_items.each do |raw_item|
        next unless raw_item.is_a?(SearchVideo)
        next if Invidious::Lightious::ShortsPolicy.short?(raw_item)
        next if results.any? { |existing| existing.id == raw_item.id }

        results << raw_item
        kinds[raw_item.id] = if raw_item.badges.live_now?
                               "Live now"
                             elsif raw_item.upcoming?
                               requested_tab == "streams" ? "Upcoming live" : "Upcoming"
                             else
                               case requested_tab
                               when "streams" then "Livestream"
                               else                "Video"
                               end
                             end
      end
    end
    results.sort! { |left, right| right.published <=> left.published }
    results = results.first(MAX_LIBRARY_SELECTIONS)
    {results, kinds}
  end

  private def channel_tab_title(tab : String) : String
    case tab
    when "videos"  then "Videos"
    when "streams" then "Livestreams"
    else                "Everything"
    end
  end

  private def channel_thumbnail_url(channel : SearchChannel) : String?
    return nil if channel.author_thumbnail.empty?

    target = URI.parse(channel.author_thumbnail).request_target.gsub(/=s\d+/, "=s176")
    "/ggpht#{target}"
  rescue URI::Error
    nil
  end

  private def channel_thumbnail_url(channel : AboutChannel) : String?
    target = URI.parse(channel.author_thumbnail).request_target.gsub(/=s\d+/, "=s176")
    "/ggpht#{target}"
  rescue URI::Error
    nil
  end

  private def valid_channel_id?(value : String) : Bool
    value.matches?(/\AUC[A-Za-z0-9_-]{22}\z/)
  end

  private def normalized_playlist_name(value : String?) : String?
    name = value.to_s.strip
    return nil if name.empty? || name.bytesize > MAX_PLAYLIST_NAME_BYTES
    name
  end

  private def notice_text(value : String?) : String?
    case value
    when "paired"               then "Phone approved. Confirm pairing on the phone."
    when "mode"                 then "Experience mode updated."
    when "video"                then "Video sent to the focused library."
    when "library"              then "Your selection was added to the library."
    when "selection-required"   then "Choose at least one video or channel."
    when "playlist-required"    then "Choose a playlist for that action."
    when "policy"               then "Playback permission updated."
    when "channel-policy"       then "Channel playback permission updated."
    when "removed"              then "Video removed from the focused library."
    when "channel-removed"      then "Channel removed from the focused library."
    when "channel-added"        then "The channel was added independently to Channels."
    when "channel-videos-added" then "The selected videos were added without changing channel access."
    when "video-bulk"           then "The selected videos were updated."
    when "video-playlist"       then "The selected videos were added to the playlist."
    when "video-removed"        then "The selected videos were removed from the main library."
    when "channel-bulk"         then "The selected channels were updated."
    when "revoked"              then "Phone access revoked."
    when "playlist-created"     then "Playlist created."
    when "playlist-renamed"     then "Playlist renamed."
    when "playlist-items"       then "Playlist videos updated."
    when "playlist-deleted"     then "Playlist deleted."
    end
  end
end
