module Invidious::Routes::API::Lightious::V1
  extend self

  MAX_JSON_BODY_BYTES            = 4096
  MAX_CHANNEL_SEARCH_QUERY_BYTES =  256
  MAX_CHANNEL_SEARCH_PAGE        =   50
  CHANNEL_SEARCH_PAGE_SIZE       =   20
  RECENT_CHANNEL_CACHE           = Invidious::Lightious::ChannelFeed::RecentCache.new

  def create_pairing(env)
    prepare_json(env)
    if retry_after = Invidious::Lightious::AbuseProtection.begin_pairing_attempt(env)
      env.response.headers["Retry-After"] = retry_after.to_s
      return error_json(429, "Too many pairing requests. Try again later.")
    end

    body = parse_json_body(env).try &.as_h?
    return error_json(400, "Invalid JSON body.") unless body

    device_label = body["deviceLabel"]?.try(&.as_s?).to_s.gsub(/\s+/, " ").strip
    if device_label.empty? || device_label.bytesize > 64
      return error_json(400, "Device label must be between 1 and 64 bytes.")
    end

    bearer_digest = body["deviceBearerDigest"]?.try(&.as_s?).to_s
    unless Invidious::Lightious::Pairing.valid_device_bearer_digest?(bearer_digest)
      return error_json(400, "Invalid device credential digest.")
    end

    now = Time.utc
    Invidious::Database::Lightious.delete_expired_pairings(now)
    user_code = Invidious::Lightious::Pairing.generate_user_code
    poll_secret = Invidious::Lightious::Pairing.generate_poll_secret
    user_code_digest = Invidious::Lightious::Pairing.user_code_digest(HMAC_KEY, user_code).not_nil!
    poll_secret_digest = Invidious::Lightious::Pairing.poll_secret_digest(HMAC_KEY, poll_secret).not_nil!
    pairing_id = Random::Secure.hex(16)
    expires_at = now + CONFIG.lightious.pairing_ttl_minutes.minutes

    begin
      Invidious::Database::Lightious.insert_pairing(
        pairing_id,
        user_code_digest,
        poll_secret_digest,
        bearer_digest,
        device_label,
        now,
        expires_at,
      )
    rescue ex : DB::Error
      LOGGER.warn("Lightious pairing creation failed: #{ex.message}")
      return error_json(409, "Could not create a unique pairing. Try again.")
    end

    env.response.status_code = 201
    JSON.build do |json|
      json.object do
        json.field "pairingId", pairing_id
        json.field "userCode", user_code
        json.field "pollSecret", poll_secret
        json.field "verificationUrl", verification_url
        json.field "expiresAt", expires_at.to_rfc3339
      end
    end
  end

  def pairing_status(env)
    prepare_json(env)
    poll_secret = bearer_token(env)
    digest = poll_secret.try do |secret|
      Invidious::Lightious::Pairing.poll_secret_digest(HMAC_KEY, secret)
    end
    return error_json(401, "Invalid pairing credential.") unless digest

    pairing = Invidious::Database::Lightious.pairing_status(env.params.url["id"], digest)
    return error_json(404, "Pairing not found.") unless pairing

    state = if pairing.expires_at <= Time.utc && pairing.state != "consumed"
              "expired"
            elsif pairing.state == "created"
              "pending"
            else
              pairing.state
            end

    JSON.build do |json|
      json.object do
        json.field "state", state
        json.field "deviceLabel", pairing.device_label
        json.field "expiresAt", pairing.expires_at.to_rfc3339
        if account = pairing.claimed_account
          json.field "account", Invidious::Lightious::Pairing.account_display(account)
        end
      end
    end
  end

  def activate_pairing(env)
    prepare_json(env)
    poll_secret = bearer_token(env)
    digest = poll_secret.try do |secret|
      Invidious::Lightious::Pairing.poll_secret_digest(HMAC_KEY, secret)
    end
    return error_json(401, "Invalid pairing credential.") unless digest

    device = Invidious::Database::Lightious.activate_pairing(
      env.params.url["id"],
      digest,
      Random::Secure.hex(16),
      Time.utc,
    )
    return error_json(409, "Pairing is not approved or has expired.") unless device

    JSON.build do |json|
      json.object do
        json.field "deviceId", device.id
        json.field "account", Invidious::Lightious::Pairing.account_display(device.account)
      end
    end
  end

  def sync(env)
    prepare_json(env)
    device = authenticated_device(env)
    return invalid_device(env) unless device

    profile = Invidious::Database::Lightious.profile_for_id(device.profile_id)
    return invalid_device(env) unless profile
    items = Invidious::Database::Lightious.items_for_profile(profile.id)
    channels = Invidious::Database::Lightious.channels_for_profile(profile.id)
    playlists = Invidious::Database::Lightious.playlists_for_profile(profile.id)
    playlists_with_items = playlists.map do |playlist|
      {playlist, Invidious::Database::Lightious.items_for_playlist(playlist.id, profile.id)}
    end
    blocked_video_ids = Invidious::Database::Lightious.blocked_video_ids_for_profile(profile.id)
    Invidious::Database::Lightious.touch_device(device.id, Time.utc)

    JSON.build do |json|
      json.object do
        json.field "deviceId", device.id
        json.field "account", Invidious::Lightious::Pairing.account_display(profile.account)
        json.field "revision", profile.revision
        json.field "mode", profile.mode
        json.field "channelFeedLimit", profile.channel_feed_limit
        json.field "hideWatched", profile.hide_watched
        json.field "blockedVideoIds", blocked_video_ids
        json.field "items" do
          json.array do
            items.each do |item|
              write_item(json, item)
            end
          end
        end
        json.field "channels" do
          json.array do
            channels.each do |channel|
              json.object do
                json.field "id", channel.id
                json.field "channelId", channel.ucid
                json.field "name", channel.title
                json.field "thumbnailUrl" do
                  if thumbnail_url = channel.thumbnail_url
                    json.string thumbnail_url
                  else
                    json.null
                  end
                end
                json.field "playbackPolicy", channel.playback_policy
              end
            end
          end
        end
        json.field "playlists" do
          json.array do
            playlists_with_items.each do |playlist, playlist_items|
              json.object do
                json.field "id", playlist.id
                json.field "name", playlist.name
                json.field "items" do
                  json.array do
                    playlist_items.each do |item|
                      write_item(json, item)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def feed(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile
    error_json(403, "Open discovery is no longer available in Lightious.")
  end

  def history(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile
    error_json(403, "Open discovery is no longer available in Lightious.")
  end

  def mark_watched(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile

    id = env.params.url["id"]
    return error_json(400, "Invalid video ID.") unless valid_video_id?(id)

    begin
      video = get_video(id, region: env.params.query["region"]?)
    rescue ex : NotFoundException
      return error_json(404, ex)
    rescue ex
      return error_json(500, ex)
    end
    return short_form_denied(env, profile, video.id) if Invidious::Lightious::ShortsPolicy.short?(video)

    policy = playback_policy(profile, video.id, video.ucid)
    return error_json(403, "This video is not in your library.") unless policy

    user = Invidious::Database::Users.select(email: device.account)
    return invalid_device(env) unless user

    env.set "user", user
    Invidious::Database::Lightious.touch_device(device.id, Time.utc)
    Invidious::Routes::API::V1::Authenticated.mark_watched(env)
  end

  def popular(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile
    error_json(403, "Open discovery is no longer available in Lightious.")
  end

  def search(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile
    error_json(403, "Open discovery is no longer available in Lightious.")
  end

  # Each channel contributes a fixed recent-release window. We intentionally
  # ignore account history here: older clients recorded playback starts there,
  # while this feed hides only explicit completion recorded by the phone.
  def channel_feed(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile

    channels = Invidious::Database::Lightious.channels_for_profile(profile.id)
    blocked_video_ids = Invidious::Database::Lightious.blocked_video_ids_for_profile(profile.id)
    windows = [] of Array(Invidious::Lightious::ChannelFeed::Entry)
    failed_channel_ids = [] of String

    # Two I/O workers keep the first load practical without starting an
    # unbounded number of simultaneous upstream channel requests.
    deadline = Time.monotonic + 60.seconds
    work = ::Channel(String).new(channels.size)
    results = ::Channel(Tuple(String, Array(Invidious::Lightious::ChannelFeed::Entry)?)).new(channels.size)
    channels.each { |saved_channel| work.send(saved_channel.ucid) }
    work.close
    Math.min(2, channels.size).times do
      spawn do
        while ucid = work.receive?
          break if Time.monotonic >= deadline
          begin
            results.send({ucid, recent_channel_entries(ucid)})
          rescue ex
            LOGGER.warn("Lightious recent feed could not load #{ucid}: #{ex.message}")
            results.send({ucid, nil})
          end
        end
      end
    end
    pending_channel_ids = channels.map(&.ucid)
    until pending_channel_ids.empty?
      remaining = deadline - Time.monotonic
      break if remaining <= Time::Span.zero
      select
      when result = results.receive
        ucid, page = result
        pending_channel_ids.delete(ucid)
        if page
          eligible = page.reject { |entry| blocked_video_ids.includes?(entry.id) }
          windows << Invidious::Lightious::ChannelFeed.recent_window([eligible], profile.channel_feed_limit)
        else
          failed_channel_ids << ucid
        end
      when timeout(remaining)
        break
      end
    end
    # A slow channel remains explicitly retryable, even if its upstream request
    # finishes and warms the cache after this response has been returned.
    failed_channel_ids.concat(pending_channel_ids)

    entries = Invidious::Lightious::ChannelFeed.combine_recent(windows)
    Invidious::Database::Lightious.touch_device(device.id, Time.utc)
    locale = env.get("preferences").as(Preferences).locale
    JSON.build do |json|
      json.object do
        json.field "videos" do
          json.array do
            entries.each { |entry| write_channel_feed_entry(json, entry, locale) }
          end
        end
        json.field "failedChannelIds", failed_channel_ids
      end
    end
  end

  def channel_videos(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile

    ucid = env.params.url["ucid"]
    return error_json(400, "Invalid channel ID.") unless valid_channel_id?(ucid)

    return focused_endpoint_denied(env) unless profile.mode == "library"
    unless Invidious::Database::Lightious.channel_policy_for(profile.id, ucid)
      return error_json(403, "This channel is not in your library.")
    end

    requested_cursor = nil
    if continuation = env.params.query["continuation"]?
      raw_continuation = Invidious::Lightious::ChannelContinuation.verify(
        HMAC_KEY,
        device.id,
        ucid,
        continuation,
        Time.utc,
      )
      return error_json(400, "Invalid or expired channel continuation.") unless raw_continuation
      requested_cursor = Invidious::Lightious::ChannelFeed.decode(raw_continuation)
      return error_json(400, "Invalid or expired channel continuation.") unless requested_cursor
    end

    begin
      channel = get_about_info(ucid)
    rescue ex : ChannelRedirect
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      return error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
    rescue ex : NotFoundException
      return error_json(404, ex)
    rescue ex
      return error_json(500, ex)
    end

    has_uploads = channel.tabs.includes?("videos")
    has_streams = channel.tabs.includes?("streams")
    cursor = requested_cursor || Invidious::Lightious::ChannelFeed.initial_cursor(
      has_uploads,
      has_streams,
    )
    cursor = Invidious::Lightious::ChannelFeed.constrain(
      cursor,
      has_uploads,
      has_streams,
    )

    begin
      uploads, uploads_position = channel_feed_source(channel, cursor.uploads, "videos")
      streams, streams_position = channel_feed_source(channel, cursor.streams, "streams")
    rescue ex
      return error_json(500, ex)
    end

    entries = Invidious::Lightious::ChannelFeed.merge([streams, uploads])
    next_cursor = Invidious::Lightious::ChannelFeed::Cursor.new(
      uploads_position,
      streams_position,
    )
    protected_continuation = unless next_cursor.complete?
      raw_cursor = Invidious::Lightious::ChannelFeed.encode(next_cursor)
      Invidious::Lightious::ChannelContinuation.mint(
        HMAC_KEY,
        device.id,
        ucid,
        raw_cursor,
        Time.utc,
      )
    end
    if !next_cursor.complete? && !protected_continuation
      return error_json(502, "Channel pagination state was too large.")
    end

    Invidious::Database::Lightious.touch_device(device.id, Time.utc)
    locale = env.get("preferences").as(Preferences).locale
    JSON.build do |json|
      json.object do
        json.field "videos" do
          json.array do
            entries.each { |entry| write_channel_feed_entry(json, entry, locale) }
          end
        end
        json.field "continuation", protected_continuation if protected_continuation
      end
    end
  end

  def channel_search(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile

    ucid = env.params.url["ucid"]
    return error_json(400, "Invalid channel ID.") unless valid_channel_id?(ucid)

    return focused_endpoint_denied(env) unless profile.mode == "library"
    unless Invidious::Database::Lightious.channel_policy_for(profile.id, ucid)
      return error_json(403, "This channel is not in your library.")
    end

    query_text = env.params.query["q"]?.to_s.strip
    return error_json(400, "Enter a channel search query.") if query_text.empty?
    if query_text.bytesize > MAX_CHANNEL_SEARCH_QUERY_BYTES
      return error_json(400, "That channel search is too long.")
    end

    page_value = env.params.query["page"]?
    page = page_value ? page_value.to_i? : 1
    return error_json(400, "Invalid channel search page.") unless page
    unless page.in?(1..MAX_CHANNEL_SEARCH_PAGE)
      return error_json(400, "Invalid channel search page.")
    end

    region = env.params.query["region"]?
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

    begin
      raw_results = Invidious::Search::Processors.channel(query)
    rescue ex
      return error_json(400, ex)
    end

    blocked_video_ids = Invidious::Database::Lightious.blocked_video_ids_for_profile(profile.id)
    entries = raw_results.compact_map do |item|
      next unless item.is_a?(SearchVideo)
      next unless item.ucid == ucid
      next if blocked_video_ids.includes?(item.id)
      next if Invidious::Lightious::ShortsPolicy.short?(item)

      channel_feed_entry(item)
    end
    next_page = page + 1 if raw_results.size >= CHANNEL_SEARCH_PAGE_SIZE && page < MAX_CHANNEL_SEARCH_PAGE

    Invidious::Database::Lightious.touch_device(device.id, Time.utc)
    locale = env.get("preferences").as(Preferences).locale
    JSON.build do |json|
      json.object do
        json.field "videos" do
          json.array do
            entries.each { |entry| write_channel_feed_entry(json, entry, locale) }
          end
        end
        json.field "nextPage", next_page if next_page
      end
    end
  end

  def video(env)
    prepare_json(env)
    device, profile = authenticated_context(env)
    return invalid_device(env) unless device && profile

    id = env.params.url["id"]
    return error_json(400, "Invalid video ID.") unless valid_video_id?(id)

    begin
      video = get_video(id, region: env.params.query["region"]?)
    rescue ex : NotFoundException
      return error_json(404, ex)
    rescue ex
      return error_json(500, ex)
    end

    return short_form_denied(env, profile, video.id) if Invidious::Lightious::ShortsPolicy.short?(video)

    policy = playback_policy(profile, video.id, video.ucid)
    return error_json(403, "This video is not in your library.") unless policy

    locale = env.get("preferences").as(Preferences).locale
    response = JSON.build do |json|
      Invidious::JSONify::APIv1.video(video, json, locale: locale, proxy: true)
    end

    Invidious::Database::Lightious.touch_device(device.id, Time.utc)
    protect_video_media(
      response,
      device,
      video.id,
      video.ucid,
      policy,
    )
  end

  def media(env)
    env.response.headers["Cache-Control"] = "private, no-store"
    env.response.headers["Referrer-Policy"] = "no-referrer"
    grant = Invidious::Lightious::MediaCapability.verify(HMAC_KEY, env.params.query, Time.utc)
    return invalid_media_capability(env) unless grant

    device = Invidious::Database::Lightious.active_device_by_id(grant.device_id)
    return invalid_media_capability(env) unless device

    profile = Invidious::Database::Lightious.profile_for_id(device.profile_id)
    return invalid_media_capability(env) unless profile

    if item = Invidious::Database::Lightious.item_for_video(profile.id, grant.video_id)
      return short_form_denied(env, profile, grant.video_id) if item.is_short
    end
    begin
      if cached_video = Invidious::Database::Videos.select(grant.video_id)
        return short_form_denied(env, profile, grant.video_id) if Invidious::Lightious::ShortsPolicy.short?(cached_video)
      end
    rescue DB::Error
      # The signed capability remains subject to the normal policy check below
      # if the optional metadata cache is temporarily unavailable.
    end

    policy = playback_policy(profile, grant.video_id, grant.author_ucid)
    return error_json(403, "This video is no longer available to this phone.") unless policy

    if policy == "listen_only" && grant.kind != "audio"
      return error_json(403, "Video playback is disabled for this item.")
    end

    source_params = URI.parse(grant.source).query_params
    response = if CONFIG.invidious_companion.present?
                 Invidious::Routes::Companion.get_lightious_video_playback(env, source_params)
               else
                 Invidious::Routes::VideoPlayback.get_video_playback(
                   env,
                   source_params,
                   response_cache_control: "private, no-store",
                   allow_cors: false,
                   close_redirects: false,
                 )
               end

    if location = env.response.headers["Location"]?
      protected_location = Invidious::Lightious::MediaCapability.mint(
        HMAC_KEY,
        device.id,
        grant.video_id,
        grant.author_ucid,
        grant.kind,
        location,
        Time.utc,
      )
      unless protected_location
        env.response.headers.delete("Location")
        return error_json(502, "The media server returned an invalid redirect.")
      end
      env.response.headers["Location"] = protected_location
    end

    response
  end

  def media_options(env)
    env.response.headers["Allow"] = "GET, HEAD, OPTIONS"
    env.response.headers["Cache-Control"] = "no-store"
    env.response.status_code = 204
  end

  private def write_item(
    json : JSON::Builder,
    item : Invidious::Database::Lightious::Item,
  )
    json.object do
      json.field "id", item.id
      json.field "videoId", item.video_id
      json.field "title", item.title
      json.field "author", item.author
      json.field "authorId" do
        if author_ucid = item.author_ucid
          json.string author_ucid
        else
          json.null
        end
      end
      json.field "lengthSeconds", item.length_seconds
      json.field "thumbnailUrl" do
        if thumbnail_url = item.thumbnail_url
          json.string thumbnail_url
        else
          json.null
        end
      end
      json.field "playbackPolicy", item.playback_policy
    end
  end

  private def recent_channel_entries(ucid : String) : Array(Invidious::Lightious::ChannelFeed::Entry)
    if cached = RECENT_CHANNEL_CACHE.get(ucid)
      return cached
    end

    channel = get_about_info(ucid)
    cursor = Invidious::Lightious::ChannelFeed.initial_cursor(
      channel.tabs.includes?("videos"),
      channel.tabs.includes?("streams"),
    )
    pages = if channel.is_age_gated
              [
                recent_age_gated_source(channel, cursor.uploads, "videos"),
                recent_age_gated_source(channel, cursor.streams, "streams"),
              ]
            else
              uploads, _ = channel_feed_source(channel, cursor.uploads, "videos")
              streams, _ = channel_feed_source(channel, cursor.streams, "streams")
              [uploads, streams].map { |page| Invidious::Lightious::ChannelFeed.newest_source(page) }
            end
    entries = Invidious::Lightious::ChannelFeed.merge(pages, preserve_order: true)
    RECENT_CHANNEL_CACHE.put(ucid, entries)
    entries
  end

  private def recent_age_gated_source(
    channel : AboutChannel,
    position : Invidious::Lightious::ChannelFeed::Position,
    source : String,
  ) : Array(Invidious::Lightious::ChannelFeed::Entry)
    return [] of Invidious::Lightious::ChannelFeed::Entry if position.complete

    playlist_prefix = source == "streams" ? "UULV" : "UULF"
    playlist = get_playlist(channel.ucid.sub("UC", playlist_prefix))
    # PlaylistVideo.published is synthesized as Time.utc by the parser. Resolve
    # only the bounded head candidates, then use real publication metadata;
    # never sort or refill the feed using that fabricated playlist timestamp.
    candidates = get_playlist_videos(playlist, offset: 0)
      .first(Invidious::Lightious::ChannelFeed::MAX_RECENT_LIMIT)
    candidates.compact_map do |item|
      next unless item.is_a?(PlaylistVideo)
      video = get_video(item.id)
      next unless video.ucid == channel.ucid
      next if Invidious::Lightious::ShortsPolicy.short?(video)
      next if video.live_now || video.premiere_timestamp
      raw_published = video.info["published"]?.try(&.as_s?)
      raise InfoException.new("Publication date unavailable for recent channel video.") unless raw_published
      published = Time.parse(raw_published, "%Y-%m-%d", Time::Location::UTC)
      Invidious::Lightious::ChannelFeed::Entry.new(
        id: video.id,
        title: video.title,
        author: video.author,
        author_id: video.ucid,
        published: published,
        views: video.views,
        length_seconds: video.length_seconds,
        premiere_timestamp: nil,
        live_now: false,
      )
    end
  end

  private def channel_feed_source(
    channel : AboutChannel,
    position : Invidious::Lightious::ChannelFeed::Position,
    source : String,
  ) : Tuple(
    Array(Invidious::Lightious::ChannelFeed::Entry),
    Invidious::Lightious::ChannelFeed::Position,
  )
    return {[] of Invidious::Lightious::ChannelFeed::Entry, position} if position.complete
    return age_gated_channel_feed_source(channel, position, source) if channel.is_age_gated

    raw_items, next_continuation = case source
                                   when "streams"
                                     Invidious::Channel::Tabs.get_livestreams(
                                       channel,
                                       continuation: position.continuation,
                                       sort_by: "newest",
                                     )
                                   else
                                     Invidious::Channel::Tabs.get_videos(
                                       channel,
                                       continuation: position.continuation,
                                       sort_by: "newest",
                                     )
                                   end
    window = Invidious::Lightious::ChannelFeed.page_window(
      raw_items.size,
      position,
      next_continuation,
    )
    entries = raw_items[window.start, window.size].compact_map do |item|
      next unless item.is_a?(SearchVideo)
      next unless item.ucid == channel.ucid
      next if Invidious::Lightious::ShortsPolicy.short?(item)
      channel_feed_entry(item)
    end
    {entries, window.next_position}
  end

  private def age_gated_channel_feed_source(
    channel : AboutChannel,
    position : Invidious::Lightious::ChannelFeed::Position,
    source : String,
  ) : Tuple(
    Array(Invidious::Lightious::ChannelFeed::Entry),
    Invidious::Lightious::ChannelFeed::Position,
  )
    playlist_prefix = case source
                      when "streams" then "UULV"
                      else                "UULF"
                      end
    playlist = get_playlist(channel.ucid.sub("UC", playlist_prefix))
    raw_items = get_playlist_videos(playlist, offset: position.offset)
    consumed = Math.min(raw_items.size, Invidious::Lightious::ChannelFeed::PER_SOURCE_PAGE_SIZE)
    entries = raw_items.first(consumed).compact_map do |item|
      next unless item.is_a?(PlaylistVideo)
      next unless item.ucid == channel.ucid
      channel_feed_entry(item)
    end
    next_offset = position.offset + consumed
    next_position = if consumed == 0 || next_offset >= playlist.video_count
                      Invidious::Lightious::ChannelFeed::Position.finished
                    else
                      Invidious::Lightious::ChannelFeed::Position.new(false, nil, next_offset)
                    end
    {entries, next_position}
  rescue InfoException
    {[] of Invidious::Lightious::ChannelFeed::Entry, Invidious::Lightious::ChannelFeed::Position.finished}
  end

  private def channel_feed_entry(item : SearchVideo) : Invidious::Lightious::ChannelFeed::Entry
    Invidious::Lightious::ChannelFeed::Entry.new(
      id: item.id,
      title: item.title,
      author: item.author,
      author_id: item.ucid,
      published: item.published,
      views: item.views,
      length_seconds: item.length_seconds,
      premiere_timestamp: item.premiere_timestamp,
      live_now: item.badges.live_now?,
    )
  end

  private def channel_feed_entry(item : PlaylistVideo) : Invidious::Lightious::ChannelFeed::Entry
    Invidious::Lightious::ChannelFeed::Entry.new(
      id: item.id,
      title: item.title,
      author: item.author,
      author_id: item.ucid,
      published: item.published,
      views: 0_i64,
      length_seconds: item.length_seconds,
      premiere_timestamp: nil,
      live_now: item.live_now,
    )
  end

  private def write_channel_feed_entry(
    json : JSON::Builder,
    entry : Invidious::Lightious::ChannelFeed::Entry,
    locale : String?,
  )
    json.object do
      json.field "type", "video"
      json.field "title", entry.title
      json.field "videoId", entry.id
      json.field "author", entry.author
      json.field "authorId", entry.author_id
      json.field "authorUrl", "/channel/#{entry.author_id}"
      json.field "videoThumbnails" do
        Invidious::JSONify::APIv1.thumbnails(json, entry.id)
      end
      json.field "viewCount", entry.views
      json.field "published", entry.published.to_unix
      json.field "publishedText", I18n.translate(locale, "`x` ago", recode_date(entry.published, locale))
      json.field "lengthSeconds", entry.length_seconds
      json.field "liveNow", entry.live_now
      json.field "isUpcoming", entry.upcoming?
      if premiere_timestamp = entry.premiere_timestamp
        json.field "premiereTimestamp", premiere_timestamp.to_unix
      end
    end
  end

  private def authenticated_context(env) : Tuple(
    Invidious::Database::Lightious::Device?,
    Invidious::Database::Lightious::Profile?,
  )
    device = authenticated_device(env)
    profile = device.try do |value|
      Invidious::Database::Lightious.profile_for_id(value.profile_id)
    end
    {device, profile}
  end

  private def safe_channel_video?(
    video : ChannelVideo,
    profile : Invidious::Database::Lightious::Profile,
  ) : Bool
    return true if video.live_now || video.premiere_timestamp
    return true if video.length_seconds > Invidious::Lightious::ShortsPolicy::MAX_SHORT_SECONDS

    # Shorts can be at most three minutes and must be portrait or square. Only
    # the small/unknown-duration subset needs a metadata lookup.
    safe_video_id?(video.id, profile)
  end

  private def safe_video_id?(
    video_id : String,
    profile : Invidious::Database::Lightious::Profile,
  ) : Bool
    video = get_video(video_id, refresh: false)
    return true unless Invidious::Lightious::ShortsPolicy.short?(video)

    Invidious::Database::Lightious.mark_video_as_short(profile.id, video_id, Time.utc)
    false
  rescue ex
    # Content of unknown form is omitted rather than risking short-form content
    # crossing the Lightious boundary.
    LOGGER.warn("Lightious omitted unclassified video #{video_id}: #{ex.message}")
    false
  end

  private def short_form_denied(
    env,
    profile : Invidious::Database::Lightious::Profile,
    video_id : String,
  )
    begin
      Invidious::Database::Lightious.mark_video_as_short(profile.id, video_id, Time.utc)
    rescue ex
      LOGGER.warn("Lightious could not persist Shorts quarantine for #{video_id}: #{ex.message}")
    end
    error_json(403, "Short-form videos are not available in Lightious.")
  end

  private def authenticated_device(env) : Invidious::Database::Lightious::Device?
    if stored = env.get?(Invidious::Lightious::DeviceAuthorization::DEVICE_CONTEXT_KEY)
      return stored.as(Invidious::Database::Lightious::Device)
    end

    digest = Invidious::Lightious::DeviceAuthorization.bearer_digest(
      env.request.headers["Authorization"]?,
    )
    digest.try { |value| Invidious::Database::Lightious.active_device(value) }
  end

  private def playback_policy(
    profile : Invidious::Database::Lightious::Profile,
    video_id : String,
    author_ucid : String?,
  ) : String?
    Invidious::Database::Lightious.playback_policy_for(
      profile.id,
      video_id,
      author_ucid,
    )
  end

  private def protect_video_media(
    response : String,
    device : Invidious::Database::Lightious::Device,
    video_id : String,
    author_ucid : String?,
    policy : String,
  ) : String
    payload = JSON.parse(response)
    object = payload.as_h
    object["playbackPolicy"] = JSON::Any.new(policy)
    object.delete("hlsUrl")
    object.delete("dashUrl")
    object.delete("captions")
    object.delete("recommendedVideos")

    protect_format_array(object, "formatStreams", "muxed", device, video_id, author_ucid, policy)
    protect_format_array(object, "adaptiveFormats", nil, device, video_id, author_ucid, policy)
    payload.to_json
  end

  private def protect_format_array(
    object : Hash(String, JSON::Any),
    field : String,
    fixed_kind : String?,
    device : Invidious::Database::Lightious::Device,
    video_id : String,
    author_ucid : String?,
    policy : String,
  )
    formats = object[field]?.try &.as_a?
    return unless formats

    protected_formats = formats.compact_map do |format|
      values = format.as_h?
      next unless values

      kind = fixed_kind || stream_kind(values["type"]?.try &.as_s?)
      next unless kind
      next if policy == "listen_only" && kind != "audio"

      raw_url = values["url"]?.try &.as_s?
      next unless raw_url
      protected_url = Invidious::Lightious::MediaCapability.mint(
        HMAC_KEY,
        device.id,
        video_id,
        author_ucid,
        kind,
        raw_url,
        Time.utc,
      )
      next unless protected_url

      values["url"] = JSON::Any.new(protected_url)
      format
    end

    object[field] = JSON::Any.new(protected_formats)
  end

  private def stream_kind(mime_type : String?) : String?
    return nil unless mime_type
    normalized = mime_type.split(';', 2)[0].strip.downcase
    return "audio" if normalized.starts_with?("audio/")
    return "video" if normalized.starts_with?("video/")

    nil
  end

  private def valid_video_id?(value : String) : Bool
    value.matches?(/\A[A-Za-z0-9_-]{11}\z/)
  end

  private def valid_channel_id?(value : String) : Bool
    value.matches?(/\AUC[A-Za-z0-9_-]{22}\z/)
  end

  private def focused_endpoint_denied(env)
    error_json(403, "This endpoint is unavailable while the phone is in Focused mode.")
  end

  private def invalid_device(env)
    prepare_json(env)
    env.response.headers["WWW-Authenticate"] = %(Bearer realm="Lightious", error="invalid_token")
    error_json(401, "Invalid device credential.")
  end

  private def invalid_media_capability(env)
    prepare_json(env)
    env.response.headers["WWW-Authenticate"] = %(Bearer realm="Lightious media", error="invalid_token")
    error_json(401, "Invalid or expired media capability.")
  end

  private def prepare_json(env)
    env.response.content_type = "application/json"
    env.response.headers["Cache-Control"] = "no-store"
  end

  private def parse_json_body(env) : JSON::Any?
    body = env.request.body.try &.gets_to_end
    return nil unless body && body.bytesize <= MAX_JSON_BODY_BYTES
    JSON.parse(body)
  rescue JSON::ParseException
    nil
  end

  private def bearer_token(env) : String?
    authorization = env.request.headers["Authorization"]?
    return nil unless authorization && authorization.starts_with?("Bearer ")
    authorization.lchop("Bearer ").strip
  end

  private def verification_url : String
    base = CONFIG.lightious.public_url.to_s.rstrip("/")
    base.empty? ? "/lightious/pair" : "#{base}/lightious/pair"
  end
end
