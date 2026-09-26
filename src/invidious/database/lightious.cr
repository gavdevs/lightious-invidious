require "./base.cr"

module Invidious::Database::Lightious
  extend self

  record Profile,
    id : String,
    account : String,
    mode : String,
    revision : Int64,
    created_at : Time,
    updated_at : Time,
    channel_feed_limit : Int32 = 3,
    hide_watched : Bool = true

  record PairingStatus,
    id : String,
    state : String,
    device_label : String,
    expires_at : Time,
    claimed_account : String?

  record Device,
    id : String,
    profile_id : String,
    label : String,
    account : String,
    created_at : Time,
    last_seen_at : Time?,
    revoked_at : Time?

  record Item,
    id : String,
    profile_id : String,
    video_id : String,
    title : String,
    author : String,
    author_ucid : String?,
    length_seconds : Int64,
    thumbnail_url : String?,
    playback_policy : String,
    library_visible : Bool,
    is_short : Bool,
    added_at : Time,
    updated_at : Time

  record ItemInput,
    item_id : String,
    video_id : String,
    title : String,
    author : String,
    author_ucid : String?,
    length_seconds : Int64,
    thumbnail_url : String?,
    playback_policy : String,
    is_short : Bool = false

  record SaveItemsResult,
    items_saved : Int32,
    playlist_memberships_added : Int32

  record Channel,
    id : String,
    profile_id : String,
    ucid : String,
    title : String,
    thumbnail_url : String?,
    playback_policy : String,
    added_at : Time,
    updated_at : Time

  record Playlist,
    id : String,
    profile_id : String,
    name : String,
    created_at : Time,
    updated_at : Time

  def ensure_profile(account : String, proposed_id : String, now : Time) : Profile
    request = <<-SQL
      INSERT INTO lightious_profiles (
        id,
        invidious_user_email,
        created_at,
        updated_at
      ) VALUES ($1, $2, $3, $3)
      ON CONFLICT (invidious_user_email) DO UPDATE
        SET invidious_user_email = EXCLUDED.invidious_user_email
      RETURNING id, invidious_user_email, mode, revision, created_at, updated_at, channel_feed_limit, hide_watched
    SQL

    row = PG_DB.query_one(
      request,
      proposed_id,
      account,
      now,
      as: {String, String, String, Int64, Time, Time, Int32, Bool},
    )
    profile_from_row(row)
  end

  def profile_for_account(account : String) : Profile?
    request = <<-SQL
      SELECT id, invidious_user_email, mode, revision, created_at, updated_at, channel_feed_limit, hide_watched
      FROM lightious_profiles
      WHERE invidious_user_email = $1
    SQL

    row = PG_DB.query_one?(
      request,
      account,
      as: {String, String, String, Int64, Time, Time, Int32, Bool},
    )
    row.try { |value| profile_from_row(value) }
  end

  def profile_for_id(id : String) : Profile?
    request = <<-SQL
      SELECT id, invidious_user_email, mode, revision, created_at, updated_at, channel_feed_limit, hide_watched
      FROM lightious_profiles
      WHERE id = $1
    SQL

    row = PG_DB.query_one?(
      request,
      id,
      as: {String, String, String, Int64, Time, Time, Int32, Bool},
    )
    row.try { |value| profile_from_row(value) }
  end

  def update_experience(
    account : String,
    mode : String,
    channel_feed_limit : Int32,
    hide_watched : Bool,
    now : Time,
  ) : Profile?
    request = <<-SQL
      UPDATE lightious_profiles
      SET
        mode = $1,
        channel_feed_limit = $2,
        hide_watched = $3,
        revision = revision + CASE
          WHEN mode = $1 AND channel_feed_limit = $2 AND hide_watched = $3 THEN 0 ELSE 1 END,
        updated_at = CASE
          WHEN mode = $1 AND channel_feed_limit = $2 AND hide_watched = $3 THEN updated_at ELSE $4 END
      WHERE invidious_user_email = $5
      RETURNING id, invidious_user_email, mode, revision, created_at, updated_at, channel_feed_limit, hide_watched
    SQL

    row = PG_DB.query_one?(
      request,
      mode,
      channel_feed_limit,
      hide_watched,
      now,
      account,
      as: {String, String, String, Int64, Time, Time, Int32, Bool},
    )
    row.try { |value| profile_from_row(value) }
  end

  def visible_items_for_profile(profile_id : String) : Array(Item)
    request = <<-SQL
      SELECT
        id,
        profile_id,
        video_id,
        title,
        author,
        author_ucid,
        length_seconds,
        thumbnail_url,
        playback_policy,
        library_visible,
        is_short,
        added_at,
        updated_at
      FROM lightious_items
      WHERE profile_id = $1 AND library_visible AND NOT is_short
      ORDER BY added_at DESC, id ASC
    SQL

    PG_DB.query_all(
      request,
      profile_id,
      as: {String, String, String, String, String, String?, Int64, String?, String, Bool, Bool, Time, Time},
    ).map { |row| item_from_row(row) }
  end

  # Preserve the original method as the top-level library query. Callers that
  # administer playlists must opt in to hidden playlist-only records.
  def items_for_profile(profile_id : String) : Array(Item)
    visible_items_for_profile(profile_id)
  end

  def all_items_for_profile(profile_id : String) : Array(Item)
    request = <<-SQL
      SELECT
        id,
        profile_id,
        video_id,
        title,
        author,
        author_ucid,
        length_seconds,
        thumbnail_url,
        playback_policy,
        library_visible,
        is_short,
        added_at,
        updated_at
      FROM lightious_items
      WHERE profile_id = $1
      ORDER BY added_at DESC, id ASC
    SQL

    PG_DB.query_all(
      request,
      profile_id,
      as: {String, String, String, String, String, String?, Int64, String?, String, Bool, Bool, Time, Time},
    ).map { |row| item_from_row(row) }
  end

  def blocked_video_ids_for_profile(profile_id : String) : Array(String)
    PG_DB.query_all(
      <<-SQL,
        SELECT DISTINCT video_id
        FROM lightious_items
        WHERE profile_id = $1 AND is_short
        ORDER BY video_id ASC
      SQL
      profile_id,
      as: String,
    )
  end

  def item_for_video(profile_id : String, video_id : String) : Item?
    request = <<-SQL
      SELECT
        id,
        profile_id,
        video_id,
        title,
        author,
        author_ucid,
        length_seconds,
        thumbnail_url,
        playback_policy,
        library_visible,
        is_short,
        added_at,
        updated_at
      FROM lightious_items
      WHERE profile_id = $1 AND video_id = $2
    SQL

    row = PG_DB.query_one?(
      request,
      profile_id,
      video_id,
      as: {String, String, String, String, String, String?, Int64, String?, String, Bool, Bool, Time, Time},
    )
    row.try { |value| item_from_row(value) }
  end

  # Quarantine a legacy item as soon as metadata positively identifies it as a
  # Short. All user-facing item queries exclude quarantined rows.
  def mark_video_as_short(profile_id : String, video_id : String, now : Time) : Bool
    request = <<-SQL
      WITH changed AS (
        UPDATE lightious_items
        SET is_short = true, updated_at = $1
        WHERE profile_id = $2 AND video_id = $3 AND NOT is_short
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $1
        WHERE id = (SELECT profile_id FROM changed LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM changed
    SQL

    PG_DB.query_one(request, now, profile_id, video_id, as: Int64) == 1
  end

  def upsert_item(
    account : String,
    item_id : String,
    video_id : String,
    title : String,
    author : String,
    length_seconds : Int64,
    thumbnail_url : String?,
    playback_policy : String,
    now : Time,
    author_ucid : String? = nil,
    library_visible : Bool = true,
    is_short : Bool = false,
  ) : Bool
    return false if is_short

    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), upserted AS (
        INSERT INTO lightious_items (
          id,
          profile_id,
          video_id,
          title,
          author,
          author_ucid,
          length_seconds,
          thumbnail_url,
          playback_policy,
          library_visible,
          is_short,
          added_at,
          updated_at
        )
        SELECT $2, target.id, $3, $4, $5, $10, $6, $7, $8, $11, $12, $9, $9
        FROM target
        WHERE true
        ON CONFLICT (profile_id, video_id) DO UPDATE SET
          title = EXCLUDED.title,
          author = EXCLUDED.author,
          author_ucid = COALESCE(EXCLUDED.author_ucid, lightious_items.author_ucid),
          length_seconds = EXCLUDED.length_seconds,
          thumbnail_url = EXCLUDED.thumbnail_url,
          playback_policy = EXCLUDED.playback_policy,
          library_visible = lightious_items.library_visible OR EXCLUDED.library_visible,
          is_short = lightious_items.is_short OR EXCLUDED.is_short,
          updated_at = EXCLUDED.updated_at
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $9
        WHERE id = (SELECT profile_id FROM upserted LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM bumped
    SQL

    PG_DB.query_one(
      request,
      account,
      item_id,
      video_id,
      title,
      author,
      length_seconds,
      thumbnail_url,
      playback_policy,
      now,
      author_ucid,
      library_visible,
      is_short,
      as: Int64,
    ) == 1
  end

  def save_video_destination(
    account : String,
    input : ItemInput,
    destination : Invidious::Lightious::LibraryDestination,
    now : Time,
    playlist_id : String? = nil,
  ) : Bool
    result = save_videos_destination(
      account,
      [input],
      destination,
      now,
      playlist_id,
    )
    result.try(&.items_saved) == 1
  end

  # Atomically stores search-selected videos and, when requested, adds them to
  # a playlist owned by the same account. Playlist-only saves remain hidden
  # from the top-level library; they still participate in playback policy and
  # are returned from items_for_playlist.
  def save_videos_destination(
    account : String,
    inputs : Array(ItemInput),
    destination : Invidious::Lightious::LibraryDestination,
    now : Time,
    playlist_id : String? = nil,
  ) : SaveItemsResult?
    unique_inputs = inputs.uniq(&.video_id)
    return SaveItemsResult.new(0, 0) if unique_inputs.empty?
    return nil if unique_inputs.any?(&.is_short)

    result : SaveItemsResult? = nil
    PG_DB.transaction do |transaction|
      connection = transaction.connection
      profile_id = connection.query_one?(
        "SELECT id FROM lightious_profiles WHERE invidious_user_email = $1",
        account,
        as: String,
      )
      next unless profile_id

      target_playlist_id : String? = nil
      if destination.playlist_membership?
        next unless requested_playlist_id = playlist_id
        target_playlist_id = connection.query_one?(
          <<-SQL,
            SELECT playlist.id
            FROM lightious_playlists AS playlist
            WHERE playlist.id = $1 AND playlist.profile_id = $2
            FOR UPDATE
          SQL
          requested_playlist_id,
          profile_id,
          as: String,
        )
        next unless target_playlist_id
      end

      membership_count = 0
      unique_inputs.each do |input|
        stored_item_id = upsert_item_without_revision(
          connection,
          profile_id,
          input,
          destination.library_visible?,
          now,
        )

        if target_playlist_id
          membership_count += connection.exec(
            <<-SQL,
              INSERT INTO lightious_playlist_items (
                playlist_id,
                item_id,
                position,
                added_at
              )
              SELECT
                $1,
                $2,
                COALESCE(MAX(position), -1) + 1,
                $3
              FROM lightious_playlist_items
              WHERE playlist_id = $1
              ON CONFLICT (playlist_id, item_id) DO NOTHING
            SQL
            target_playlist_id,
            stored_item_id,
            now,
          ).rows_affected.to_i32
        end
      end

      connection.exec(
        <<-SQL,
          UPDATE lightious_profiles
          SET revision = revision + 1, updated_at = $1
          WHERE id = $2
        SQL
        now,
        profile_id,
      )
      result = SaveItemsResult.new(unique_inputs.size.to_i32, membership_count)
    end

    result
  end

  def channels_for_profile(profile_id : String) : Array(Channel)
    request = <<-SQL
      SELECT
        id,
        profile_id,
        ucid,
        title,
        thumbnail_url,
        playback_policy,
        added_at,
        updated_at
      FROM lightious_channels
      WHERE profile_id = $1
      ORDER BY added_at DESC, id ASC
    SQL

    PG_DB.query_all(
      request,
      profile_id,
      as: {String, String, String, String, String?, String, Time, Time},
    ).map { |row| channel_from_row(row) }
  end

  def upsert_channel(
    account : String,
    channel_id : String,
    ucid : String,
    title : String,
    thumbnail_url : String?,
    playback_policy : String,
    now : Time,
  ) : Bool
    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), upserted AS (
        INSERT INTO lightious_channels (
          id,
          profile_id,
          ucid,
          title,
          thumbnail_url,
          playback_policy,
          added_at,
          updated_at
        )
        SELECT $2, target.id, $3, $4, $5, $6, $7, $7
        FROM target
        WHERE true
        ON CONFLICT (profile_id, ucid) DO UPDATE SET
          title = EXCLUDED.title,
          thumbnail_url = EXCLUDED.thumbnail_url,
          playback_policy = EXCLUDED.playback_policy,
          updated_at = EXCLUDED.updated_at
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $7
        WHERE id = (SELECT profile_id FROM upserted LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM bumped
    SQL

    PG_DB.query_one(
      request,
      account,
      channel_id,
      ucid,
      title,
      thumbnail_url,
      playback_policy,
      now,
      as: Int64,
    ) == 1
  end

  def update_channel_policy(account : String, channel_id : String, policy : String, now : Time) : Bool
    bulk_update_channel_policy(account, [channel_id], policy, now) == 1
  end

  def bulk_update_channel_policy(
    account : String,
    channel_ids : Array(String),
    policy : String,
    now : Time,
  ) : Int32
    unique_channel_ids = channel_ids.uniq
    return 0 if unique_channel_ids.empty?

    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), changed AS (
        UPDATE lightious_channels
        SET playback_policy = $2, updated_at = $3
        WHERE id = ANY($4::text[])
          AND profile_id = (SELECT id FROM target)
          AND playback_policy <> $2
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $3
        WHERE id = (SELECT profile_id FROM changed LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM changed
    SQL

    PG_DB.query_one(
      request,
      account,
      policy,
      now,
      unique_channel_ids,
      as: Int64,
    ).to_i32
  end

  def delete_channel(account : String, channel_id : String, now : Time) : Bool
    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), removed AS (
        DELETE FROM lightious_channels
        WHERE id = $2
          AND profile_id = (SELECT id FROM target)
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $3
        WHERE id = (SELECT profile_id FROM removed LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM bumped
    SQL

    PG_DB.query_one(request, account, channel_id, now, as: Int64) == 1
  end

  def playlists_for_profile(profile_id : String) : Array(Playlist)
    request = <<-SQL
      SELECT id, profile_id, name, created_at, updated_at
      FROM lightious_playlists
      WHERE profile_id = $1
      ORDER BY created_at DESC, id ASC
    SQL

    PG_DB.query_all(
      request,
      profile_id,
      as: {String, String, String, Time, Time},
    ).map { |row| playlist_from_row(row) }
  end

  def items_for_playlist(playlist_id : String, profile_id : String) : Array(Item)
    request = <<-SQL
      SELECT
        item.id,
        item.profile_id,
        item.video_id,
        item.title,
        item.author,
        item.author_ucid,
        item.length_seconds,
        item.thumbnail_url,
        item.playback_policy,
        item.library_visible,
        item.is_short,
        item.added_at,
        item.updated_at
      FROM lightious_playlist_items AS membership
      JOIN lightious_playlists AS playlist
        ON playlist.id = membership.playlist_id
        AND playlist.profile_id = $2
      JOIN lightious_items AS item
        ON item.id = membership.item_id
        AND item.profile_id = playlist.profile_id
      WHERE membership.playlist_id = $1
        AND NOT item.is_short
      ORDER BY membership.position ASC, item.id ASC
    SQL

    PG_DB.query_all(
      request,
      playlist_id,
      profile_id,
      as: {String, String, String, String, String, String?, Int64, String?, String, Bool, Bool, Time, Time},
    ).map { |row| item_from_row(row) }
  end

  def create_playlist(
    account : String,
    playlist_id : String,
    name : String,
    now : Time,
  ) : Bool
    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), inserted AS (
        INSERT INTO lightious_playlists (
          id,
          profile_id,
          name,
          created_at,
          updated_at
        )
        SELECT $2, target.id, $3, $4, $4
        FROM target
        WHERE true
        ON CONFLICT (id) DO NOTHING
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $4
        WHERE id = (SELECT profile_id FROM inserted LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM bumped
    SQL

    PG_DB.query_one(request, account, playlist_id, name, now, as: Int64) == 1
  end

  def rename_playlist(
    account : String,
    playlist_id : String,
    name : String,
    now : Time,
  ) : Bool
    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), changed AS (
        UPDATE lightious_playlists
        SET name = $2, updated_at = $3
        WHERE id = $4
          AND profile_id = (SELECT id FROM target)
          AND name <> $2
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $3
        WHERE id = (SELECT profile_id FROM changed LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM bumped
    SQL

    PG_DB.query_one(request, account, name, now, playlist_id, as: Int64) == 1
  end

  def delete_playlist(account : String, playlist_id : String, now : Time) : Bool
    deleted = false
    PG_DB.transaction do |transaction|
      connection = transaction.connection
      profile_id = connection.query_one?(
        <<-SQL,
          SELECT playlist.profile_id
          FROM lightious_playlists AS playlist
          JOIN lightious_profiles AS profile ON profile.id = playlist.profile_id
          WHERE playlist.id = $1 AND profile.invidious_user_email = $2
          FOR UPDATE OF playlist
        SQL
        playlist_id,
        account,
        as: String,
      )
      next unless profile_id

      removed = connection.exec(
        "DELETE FROM lightious_playlists WHERE id = $1 AND profile_id = $2",
        playlist_id,
        profile_id,
      )
      next unless removed.rows_affected == 1

      delete_hidden_orphans_for_profile(connection, profile_id)
      bump_profile_revision(connection, profile_id, now)
      deleted = true
    end
    deleted
  end

  def add_playlist_items(
    account : String,
    playlist_id : String,
    item_ids : Array(String),
    now : Time,
  ) : Int32
    unique_item_ids = item_ids.uniq
    return 0 if unique_item_ids.empty?

    request = <<-SQL
      WITH target AS (
        SELECT playlist.id, playlist.profile_id
        FROM lightious_playlists AS playlist
        JOIN lightious_profiles AS profile ON profile.id = playlist.profile_id
        WHERE profile.invidious_user_email = $1
          AND playlist.id = $2
        FOR UPDATE OF playlist
      ), last_position AS (
        SELECT COALESCE(MAX(membership.position), -1) AS value
        FROM lightious_playlist_items AS membership
        JOIN target ON target.id = membership.playlist_id
      ), candidates AS (
        SELECT
          item.id,
          ROW_NUMBER() OVER (ORDER BY requested.ordinality) AS offset
        FROM unnest($3::text[]) WITH ORDINALITY AS requested(id, ordinality)
        JOIN lightious_items AS item ON item.id = requested.id
        JOIN target ON target.profile_id = item.profile_id
        LEFT JOIN lightious_playlist_items AS existing
          ON existing.playlist_id = target.id
          AND existing.item_id = item.id
        WHERE existing.item_id IS NULL
          AND NOT item.is_short
      ), inserted AS (
        INSERT INTO lightious_playlist_items (
          playlist_id,
          item_id,
          position,
          added_at
        )
        SELECT
          target.id,
          candidates.id,
          (last_position.value + candidates.offset)::integer,
          $4
        FROM target, last_position, candidates
        RETURNING playlist_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $4
        WHERE id = (SELECT profile_id FROM target LIMIT 1)
          AND EXISTS (SELECT 1 FROM inserted)
        RETURNING id
      )
      SELECT COUNT(*) FROM inserted
    SQL

    PG_DB.query_one(
      request,
      account,
      playlist_id,
      unique_item_ids,
      now,
      as: Int64,
    ).to_i32
  end

  def remove_playlist_item(
    account : String,
    playlist_id : String,
    item_id : String,
    now : Time,
  ) : Bool
    removed = false
    PG_DB.transaction do |transaction|
      connection = transaction.connection
      profile_id = connection.query_one?(
        <<-SQL,
          SELECT playlist.profile_id
          FROM lightious_playlists AS playlist
          JOIN lightious_profiles AS profile ON profile.id = playlist.profile_id
          JOIN lightious_items AS item ON item.profile_id = playlist.profile_id
          WHERE playlist.id = $1
            AND profile.invidious_user_email = $2
            AND item.id = $3
          FOR UPDATE OF playlist, item
        SQL
        playlist_id,
        account,
        item_id,
        as: String,
      )
      next unless profile_id

      membership = connection.exec(
        <<-SQL,
          DELETE FROM lightious_playlist_items
          WHERE playlist_id = $1 AND item_id = $2
        SQL
        playlist_id,
        item_id,
      )
      next unless membership.rows_affected == 1

      delete_hidden_orphans_for_profile(connection, profile_id)
      bump_profile_revision(connection, profile_id, now)
      removed = true
    end
    removed
  end

  def update_item_policy(account : String, item_id : String, policy : String, now : Time) : Bool
    bulk_update_item_policy(account, [item_id], policy, now) == 1
  end

  def bulk_update_item_policy(
    account : String,
    item_ids : Array(String),
    policy : String,
    now : Time,
  ) : Int32
    unique_item_ids = item_ids.uniq
    return 0 if unique_item_ids.empty?

    request = <<-SQL
      WITH target AS (
        SELECT id
        FROM lightious_profiles
        WHERE invidious_user_email = $1
      ), changed AS (
        UPDATE lightious_items
        SET playback_policy = $2, updated_at = $3
        WHERE id = ANY($4::text[])
          AND profile_id = (SELECT id FROM target)
          AND playback_policy <> $2
        RETURNING profile_id
      ), bumped AS (
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $3
        WHERE id = (SELECT profile_id FROM changed LIMIT 1)
        RETURNING id
      )
      SELECT COUNT(*) FROM changed
    SQL

    PG_DB.query_one(
      request,
      account,
      policy,
      now,
      unique_item_ids,
      as: Int64,
    ).to_i32
  end

  def remove_item_from_library(account : String, item_id : String, now : Time) : Bool
    hidden = false
    PG_DB.transaction do |transaction|
      connection = transaction.connection
      profile_id = connection.query_one?(
        <<-SQL,
          UPDATE lightious_items AS item
          SET library_visible = false, updated_at = $1
          FROM lightious_profiles AS profile
          WHERE item.id = $2
            AND item.profile_id = profile.id
            AND profile.invidious_user_email = $3
            AND item.library_visible
          RETURNING item.profile_id
        SQL
        now,
        item_id,
        account,
        as: String,
      )
      next unless profile_id

      delete_hidden_orphans_for_profile(connection, profile_id)
      bump_profile_revision(connection, profile_id, now)
      hidden = true
    end
    hidden
  end

  # Existing controller call sites use delete_item for removing a video from
  # the top-level library. Playlist memberships now survive that operation.
  def delete_item(account : String, item_id : String, now : Time) : Bool
    remove_item_from_library(account, item_id, now)
  end

  def cleanup_hidden_orphans(account : String, now : Time) : Int32
    deleted_count = 0
    PG_DB.transaction do |transaction|
      connection = transaction.connection
      profile_id = connection.query_one?(
        "SELECT id FROM lightious_profiles WHERE invidious_user_email = $1",
        account,
        as: String,
      )
      next unless profile_id

      deleted_count = delete_hidden_orphans_for_profile(connection, profile_id)
      bump_profile_revision(connection, profile_id, now) if deleted_count > 0
    end
    deleted_count
  end

  def delete_expired_pairings(now : Time)
    request = <<-SQL
      DELETE FROM lightious_pairings
      WHERE expires_at <= $1
        AND state IN ('created', 'claimed', 'rejected')
    SQL
    PG_DB.exec(request, now)
  end

  def insert_pairing(
    id : String,
    user_code_digest : String,
    poll_secret_digest : String,
    device_bearer_digest : String,
    device_label : String,
    created_at : Time,
    expires_at : Time,
  )
    request = <<-SQL
      INSERT INTO lightious_pairings (
        id,
        user_code_digest,
        poll_secret_digest,
        device_bearer_digest,
        device_label,
        state,
        expires_at,
        created_at
      ) VALUES ($1, $2, $3, $4, $5, 'created', $6, $7)
    SQL

    PG_DB.exec(
      request,
      id,
      user_code_digest,
      poll_secret_digest,
      device_bearer_digest,
      device_label,
      expires_at,
      created_at,
    )
  end

  def pairing_for_user_code(user_code_digest : String, now : Time) : PairingStatus?
    request = <<-SQL
      SELECT id, state, device_label, expires_at, NULL::text
      FROM lightious_pairings
      WHERE user_code_digest = $1
        AND state = 'created'
        AND expires_at > $2
    SQL

    row = PG_DB.query_one?(
      request,
      user_code_digest,
      now,
      as: {String, String, String, Time, String?},
    )
    row.try { |value| pairing_from_row(value) }
  end

  def claim_pairing(
    user_code_digest : String,
    account : String,
    proposed_profile_id : String,
    claimed_at : Time,
  ) : PairingStatus?
    request = <<-SQL
      WITH profile AS (
        INSERT INTO lightious_profiles (
          id,
          invidious_user_email,
          created_at,
          updated_at
        ) VALUES ($1, $2, $3, $3)
        ON CONFLICT (invidious_user_email) DO UPDATE
          SET invidious_user_email = EXCLUDED.invidious_user_email
        RETURNING id, invidious_user_email
      )
      UPDATE lightious_pairings AS pairing
      SET
        state = 'claimed',
        claimed_profile_id = (SELECT id FROM profile),
        claimed_at = $3
      WHERE pairing.user_code_digest = $4
        AND pairing.state = 'created'
        AND pairing.expires_at > $3
      RETURNING
        pairing.id,
        pairing.state,
        pairing.device_label,
        pairing.expires_at,
        (SELECT invidious_user_email FROM profile)
    SQL

    row = PG_DB.query_one?(
      request,
      proposed_profile_id,
      account,
      claimed_at,
      user_code_digest,
      as: {String, String, String, Time, String},
    )
    row.try { |value| pairing_from_row(value) }
  end

  def pairing_status(id : String, poll_secret_digest : String) : PairingStatus?
    request = <<-SQL
      SELECT
        pairing.id,
        pairing.state,
        pairing.device_label,
        pairing.expires_at,
        profile.invidious_user_email
      FROM lightious_pairings AS pairing
      LEFT JOIN lightious_profiles AS profile
        ON profile.id = pairing.claimed_profile_id
      WHERE pairing.id = $1
        AND pairing.poll_secret_digest = $2
    SQL

    row = PG_DB.query_one?(
      request,
      id,
      poll_secret_digest,
      as: {String, String, String, Time, String?},
    )
    row.try { |value| pairing_from_row(value) }
  end

  # A retry after a lost activation response returns the same device. The
  # plaintext phone credential is never stored by or returned from the server.
  def activate_pairing(
    pairing_id : String,
    poll_secret_digest : String,
    device_id : String,
    activated_at : Time,
  ) : Device?
    request = <<-SQL
      WITH consumed AS (
        UPDATE lightious_pairings
        SET state = 'consumed'
        WHERE id = $1
          AND poll_secret_digest = $2
          AND state = 'claimed'
          AND expires_at > $3
        RETURNING claimed_profile_id, device_bearer_digest, device_label
      ), inserted AS (
        INSERT INTO lightious_devices (
          id,
          profile_id,
          bearer_digest,
          label,
          created_at
        )
        SELECT $4, claimed_profile_id, device_bearer_digest, device_label, $3
        FROM consumed
        ON CONFLICT (bearer_digest) DO NOTHING
        RETURNING id, profile_id, label, created_at, last_seen_at, revoked_at
      ), selected AS (
        SELECT id, profile_id, label, created_at, last_seen_at, revoked_at
        FROM inserted
        UNION ALL
        SELECT device.id, device.profile_id, device.label, device.created_at,
          device.last_seen_at, device.revoked_at
        FROM lightious_pairings AS pairing
        JOIN lightious_devices AS device
          ON device.bearer_digest = pairing.device_bearer_digest
        WHERE pairing.id = $1
          AND pairing.poll_secret_digest = $2
          AND pairing.state = 'consumed'
          AND NOT EXISTS (SELECT 1 FROM inserted)
      )
      SELECT
        device.id,
        device.profile_id,
        device.label,
        profile.invidious_user_email,
        device.created_at,
        device.last_seen_at,
        device.revoked_at
      FROM selected AS device
      JOIN lightious_profiles AS profile ON profile.id = device.profile_id
      LIMIT 1
    SQL

    row = PG_DB.query_one?(
      request,
      pairing_id,
      poll_secret_digest,
      activated_at,
      device_id,
      as: {String, String, String, String, Time, Time?, Time?},
    )
    row.try { |value| device_from_row(value) }
  end

  def active_device(bearer_digest : String) : Device?
    request = <<-SQL
      SELECT
        device.id,
        device.profile_id,
        device.label,
        profile.invidious_user_email,
        device.created_at,
        device.last_seen_at,
        device.revoked_at
      FROM lightious_devices AS device
      JOIN lightious_profiles AS profile ON profile.id = device.profile_id
      JOIN users AS account ON account.email = profile.invidious_user_email
      WHERE device.bearer_digest = $1
        AND device.revoked_at IS NULL
    SQL

    row = PG_DB.query_one?(
      request,
      bearer_digest,
      as: {String, String, String, String, Time, Time?, Time?},
    )
    row.try { |value| device_from_row(value) }
  end

  def active_device_by_id(id : String) : Device?
    request = <<-SQL
      SELECT
        device.id,
        device.profile_id,
        device.label,
        profile.invidious_user_email,
        device.created_at,
        device.last_seen_at,
        device.revoked_at
      FROM lightious_devices AS device
      JOIN lightious_profiles AS profile ON profile.id = device.profile_id
      JOIN users AS account ON account.email = profile.invidious_user_email
      WHERE device.id = $1
        AND device.revoked_at IS NULL
    SQL

    row = PG_DB.query_one?(
      request,
      id,
      as: {String, String, String, String, Time, Time?, Time?},
    )
    row.try { |value| device_from_row(value) }
  end

  # Exact-video policy wins over a whole-channel default. A nil result means
  # the profile has no grant for this video.
  def playback_policy_for(
    profile_id : String,
    video_id : String,
    author_ucid : String?,
  ) : String?
    request = <<-SQL
      SELECT COALESCE(
        (
          SELECT item.playback_policy
          FROM lightious_items AS item
          WHERE item.profile_id = $1
            AND item.video_id = $2
            AND NOT item.is_short
            AND (
              item.library_visible
              OR EXISTS (
                SELECT 1
                FROM lightious_playlist_items AS membership
                WHERE membership.item_id = item.id
              )
            )
          LIMIT 1
        ),
        (
          SELECT playback_policy
          FROM lightious_channels
          WHERE profile_id = $1 AND ucid = $3
          LIMIT 1
        )
      )
    SQL

    PG_DB.query_one(request, profile_id, video_id, author_ucid, as: String?)
  end

  def channel_policy_for(profile_id : String, author_ucid : String) : String?
    request = <<-SQL
      SELECT playback_policy
      FROM lightious_channels
      WHERE profile_id = $1 AND ucid = $2
    SQL

    PG_DB.query_one?(request, profile_id, author_ucid, as: String)
  end

  def touch_device(id : String, seen_at : Time)
    request = <<-SQL
      UPDATE lightious_devices
      SET last_seen_at = $1
      WHERE id = $2 AND revoked_at IS NULL
    SQL
    PG_DB.exec(request, seen_at, id)
  end

  def devices_for_account(account : String) : Array(Device)
    request = <<-SQL
      SELECT
        device.id,
        device.profile_id,
        device.label,
        profile.invidious_user_email,
        device.created_at,
        device.last_seen_at,
        device.revoked_at
      FROM lightious_devices AS device
      JOIN lightious_profiles AS profile ON profile.id = device.profile_id
      WHERE profile.invidious_user_email = $1
      ORDER BY device.created_at DESC
    SQL

    PG_DB.query_all(
      request,
      account,
      as: {String, String, String, String, Time, Time?, Time?},
    ).map { |row| device_from_row(row) }
  end

  def revoke_device(id : String, account : String, revoked_at : Time) : Bool
    request = <<-SQL
      UPDATE lightious_devices AS device
      SET revoked_at = $1
      FROM lightious_profiles AS profile
      WHERE device.id = $2
        AND device.profile_id = profile.id
        AND profile.invidious_user_email = $3
        AND device.revoked_at IS NULL
    SQL

    PG_DB.exec(request, revoked_at, id, account).rows_affected == 1
  end

  private def upsert_item_without_revision(
    connection : DB::Connection,
    profile_id : String,
    input : ItemInput,
    library_visible : Bool,
    now : Time,
  ) : String
    connection.query_one(
      <<-SQL,
        INSERT INTO lightious_items (
          id,
          profile_id,
          video_id,
          title,
          author,
          author_ucid,
          length_seconds,
          thumbnail_url,
          playback_policy,
          library_visible,
          is_short,
          added_at,
          updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)
        ON CONFLICT (profile_id, video_id) DO UPDATE SET
          title = EXCLUDED.title,
          author = EXCLUDED.author,
          author_ucid = COALESCE(EXCLUDED.author_ucid, lightious_items.author_ucid),
          length_seconds = EXCLUDED.length_seconds,
          thumbnail_url = EXCLUDED.thumbnail_url,
          playback_policy = EXCLUDED.playback_policy,
          library_visible = lightious_items.library_visible OR EXCLUDED.library_visible,
          is_short = lightious_items.is_short OR EXCLUDED.is_short,
          updated_at = EXCLUDED.updated_at
        RETURNING id
      SQL
      input.item_id,
      profile_id,
      input.video_id,
      input.title,
      input.author,
      input.author_ucid,
      input.length_seconds,
      input.thumbnail_url,
      input.playback_policy,
      library_visible,
      input.is_short,
      now,
      as: String,
    )
  end

  private def delete_hidden_orphans_for_profile(
    connection : DB::Connection,
    profile_id : String,
  ) : Int32
    connection.exec(
      <<-SQL,
        DELETE FROM lightious_items AS item
        WHERE item.profile_id = $1
          AND NOT item.library_visible
          AND NOT EXISTS (
            SELECT 1
            FROM lightious_playlist_items AS membership
            WHERE membership.item_id = item.id
          )
      SQL
      profile_id,
    ).rows_affected.to_i32
  end

  private def bump_profile_revision(
    connection : DB::Connection,
    profile_id : String,
    now : Time,
  )
    connection.exec(
      <<-SQL,
        UPDATE lightious_profiles
        SET revision = revision + 1, updated_at = $1
        WHERE id = $2
      SQL
      now,
      profile_id,
    )
  end

  private def profile_from_row(row : {String, String, String, Int64, Time, Time, Int32, Bool}) : Profile
    Profile.new(
      id: row[0],
      account: row[1],
      mode: row[2],
      revision: row[3],
      created_at: row[4],
      updated_at: row[5],
      channel_feed_limit: row[6],
      hide_watched: row[7],
    )
  end

  private def pairing_from_row(row : {String, String, String, Time, String?}) : PairingStatus
    PairingStatus.new(
      id: row[0],
      state: row[1],
      device_label: row[2],
      expires_at: row[3],
      claimed_account: row[4],
    )
  end

  private def device_from_row(
    row : {String, String, String, String, Time, Time?, Time?},
  ) : Device
    Device.new(
      id: row[0],
      profile_id: row[1],
      label: row[2],
      account: row[3],
      created_at: row[4],
      last_seen_at: row[5],
      revoked_at: row[6],
    )
  end

  private def item_from_row(
    row : {String, String, String, String, String, String?, Int64, String?, String, Bool, Bool, Time, Time},
  ) : Item
    Item.new(
      id: row[0],
      profile_id: row[1],
      video_id: row[2],
      title: row[3],
      author: row[4],
      author_ucid: row[5],
      length_seconds: row[6],
      thumbnail_url: row[7],
      playback_policy: row[8],
      library_visible: row[9],
      is_short: row[10],
      added_at: row[11],
      updated_at: row[12],
    )
  end

  private def channel_from_row(
    row : {String, String, String, String, String?, String, Time, Time},
  ) : Channel
    Channel.new(
      id: row[0],
      profile_id: row[1],
      ucid: row[2],
      title: row[3],
      thumbnail_url: row[4],
      playback_policy: row[5],
      added_at: row[6],
      updated_at: row[7],
    )
  end

  private def playlist_from_row(row : {String, String, String, Time, Time}) : Playlist
    Playlist.new(
      id: row[0],
      profile_id: row[1],
      name: row[2],
      created_at: row[3],
      updated_at: row[4],
    )
  end
end
