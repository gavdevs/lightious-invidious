require "pg"

module Invidious::Database
  extend self

  # Checks table integrity
  #
  # Note: config is passed as a parameter to avoid complex
  # dependencies between different parts of the software.
  def check_integrity(cfg)
    if cfg.check_tables
      Invidious::Database.check_enum("privacy", PlaylistPrivacy)

      Invidious::Database.check_table("channels", InvidiousChannel)
      Invidious::Database.check_table("channel_videos", ChannelVideo)
      Invidious::Database.check_table("playlists", InvidiousPlaylist)
      Invidious::Database.check_table("playlist_videos", PlaylistVideo)
      Invidious::Database.check_table("nonces", Nonce)
      Invidious::Database.check_table("session_ids", SessionId)
      Invidious::Database.check_table("users", User)
      Invidious::Database.check_table("videos", Video)
    end

    Invidious::Database.ensure_lightious_schema if cfg.lightious.enabled

    if cfg.check_tables && cfg.cache_annotations
      Invidious::Database.check_table("annotations", Annotation)
    end
  end

  # Lightious is an optional application feature rather than a core Invidious
  # table check. Provision its schema whenever the feature is enabled so an
  # ordinary server restart is enough to upgrade an existing installation,
  # even when the expensive general-purpose `check_tables` option is disabled.
  def ensure_lightious_schema
    PG_DB.using_connection do |db_conn|
      ensure_lightious_schema(db_conn.as(PG::Connection))
    end
  end

  def ensure_lightious_schema(conn : PG::Connection)
    conn.exec("SELECT pg_advisory_lock(hashtext('invidious'), hashtext('lightious-schema'))")

    begin
      ensure_lightious_table(conn, "lightious_profiles")
      ensure_lightious_profile_mode_default(conn)
      ensure_lightious_profile_feed_settings(conn)
      ensure_lightious_item_library_visibility_column(conn)
      ensure_lightious_item_short_column(conn)
      ensure_lightious_table(conn, "lightious_items")
      ensure_lightious_item_library_visibility(conn)
      ensure_lightious_item_short_policy(conn)
      ensure_lightious_item_author_column(conn)
      backfill_lightious_item_authors(conn)
      ensure_lightious_item_author_constraint(conn)

      ensure_lightious_table(conn, "lightious_channels")
      ensure_lightious_table(conn, "lightious_playlists")
      ensure_lightious_playlist_name_constraint(conn)
      ensure_lightious_table(conn, "lightious_playlist_items")
      ensure_lightious_table(conn, "lightious_pairings")
      ensure_lightious_table(conn, "lightious_devices")
    ensure
      conn.exec("SELECT pg_advisory_unlock(hashtext('invidious'), hashtext('lightious-schema'))")
    end
  end

  private def ensure_lightious_table(conn : PG::Connection, table_name : String)
    conn.exec_all(File.read("config/sql/#{table_name}.sql"))
  end

  private def ensure_lightious_profile_mode_default(conn : PG::Connection)
    # CREATE TABLE IF NOT EXISTS does not update an existing column default.
    # Preserve every user's selected mode while making only future profiles
    # Focused-first when an older Lightious schema is upgraded in place.
    conn.exec <<-SQL
    ALTER TABLE public.lightious_profiles
      ALTER COLUMN mode SET DEFAULT 'focused';
    SQL
  end

  private def ensure_lightious_profile_feed_settings(conn : PG::Connection)
    # Existing installations start without --migrate. Upgrade the profile here
    # as well as in the versioned migration, under the startup schema lock.
    # A single statement makes the constraint replacement and mode conversion
    # atomic; repeated starts preserve settings and do not revise profiles.
    conn.exec <<-SQL
    DO $$
    BEGIN
      ALTER TABLE public.lightious_profiles
        ADD COLUMN IF NOT EXISTS channel_feed_limit integer NOT NULL DEFAULT 3,
        ADD COLUMN IF NOT EXISTS hide_watched boolean NOT NULL DEFAULT true;

      ALTER TABLE public.lightious_profiles
        DROP CONSTRAINT IF EXISTS lightious_profiles_mode_check,
        DROP CONSTRAINT IF EXISTS lightious_profiles_channel_feed_limit_check;

      UPDATE public.lightious_profiles
      SET mode = 'library', revision = revision + 1, updated_at = now()
      WHERE mode = 'explore';

      ALTER TABLE public.lightious_profiles
        ADD CONSTRAINT lightious_profiles_mode_check CHECK (mode IN ('library', 'focused')),
        ADD CONSTRAINT lightious_profiles_channel_feed_limit_check CHECK (channel_feed_limit BETWEEN 1 AND 5);
    END
    $$;
    SQL
  end

  private def ensure_lightious_item_author_column(conn : PG::Connection)
    conn.exec("ALTER TABLE public.lightious_items ADD COLUMN IF NOT EXISTS author_ucid text")

    # A partially deployed schema may have accepted malformed identifiers before
    # the constraint was present. Treat those values as unknown so provisioning
    # remains repeatable and a valid cached value can replace them below.
    conn.exec <<-SQL
    UPDATE public.lightious_items
    SET author_ucid = NULL
    WHERE author_ucid IS NOT NULL
      AND author_ucid !~ '^UC[A-Za-z0-9_-]{22}$';
    SQL
  end

  private def ensure_lightious_item_library_visibility_column(conn : PG::Connection)
    # The table SQL creates a partial index that references this column. Add the
    # column first on legacy tables; a fresh install creates both together from
    # config/sql/lightious_items.sql.
    conn.exec <<-SQL
    DO $$
    BEGIN
      IF to_regclass('public.lightious_items') IS NOT NULL THEN
        ALTER TABLE public.lightious_items
          ADD COLUMN IF NOT EXISTS library_visible boolean;
      END IF;
    END
    $$;
    SQL
  end

  private def ensure_lightious_item_short_column(conn : PG::Connection)
    # The fresh-table SQL has an index predicate that references this column.
    # Add it before reading that file when upgrading an existing installation.
    conn.exec <<-SQL
    DO $$
    BEGIN
      IF to_regclass('public.lightious_items') IS NOT NULL THEN
        ALTER TABLE public.lightious_items
          ADD COLUMN IF NOT EXISTS is_short boolean;
      END IF;
    END
    $$;
    SQL
  end

  private def ensure_lightious_item_library_visibility(conn : PG::Connection)
    # CREATE TABLE IF NOT EXISTS does not add columns to an existing table.
    # Existing items were all top-level library entries before playlist-only
    # storage existed, so the only safe upgrade value is visible.
    conn.exec("ALTER TABLE public.lightious_items ADD COLUMN IF NOT EXISTS library_visible boolean")
    conn.exec("UPDATE public.lightious_items SET library_visible = true WHERE library_visible IS NULL")
    conn.exec <<-SQL
    ALTER TABLE public.lightious_items
      ALTER COLUMN library_visible SET DEFAULT true,
      ALTER COLUMN library_visible SET NOT NULL;
    SQL
    conn.exec <<-SQL
    CREATE INDEX IF NOT EXISTS lightious_items_profile_library_added_at_idx
      ON public.lightious_items (profile_id, added_at DESC)
      WHERE library_visible;
    SQL
  end

  private def ensure_lightious_item_short_policy(conn : PG::Connection)
    conn.exec("ALTER TABLE public.lightious_items ADD COLUMN IF NOT EXISTS is_short boolean")
    conn.exec("UPDATE public.lightious_items SET is_short = false WHERE is_short IS NULL")

    # Existing Lightious rows predate the explicit marker. Quarantine only the
    # entries that cached metadata can positively identify by the Shorts length
    # limit and square/portrait video streams. Ambiguous legacy rows remain
    # available until their metadata is refreshed at playback time.
    begin
      result = conn.exec <<-SQL
      UPDATE public.lightious_items AS item
      SET is_short = true
      FROM public.videos AS cached
      WHERE cached.id = item.video_id
        AND NOT item.is_short
        AND item.length_seconds BETWEEN 1 AND 180
        AND COALESCE(cached.info::jsonb ->> 'videoType', 'Video') = 'Video'
        AND jsonb_path_exists(
          cached.info::jsonb,
          '$.streamingData.*[*] ? (@.width > 0 && @.height > 0 && @.height >= @.width)'
        );
      SQL
      LOGGER.info("ensure_lightious_schema: quarantined #{result.rows_affected} cached Shorts") if result.rows_affected > 0
    rescue ex
      LOGGER.warn("ensure_lightious_schema: could not classify cached Shorts: #{ex.message}")
    end

    conn.exec <<-SQL
    ALTER TABLE public.lightious_items
      ALTER COLUMN is_short SET DEFAULT false,
      ALTER COLUMN is_short SET NOT NULL;
    SQL
    conn.exec("DROP INDEX IF EXISTS public.lightious_items_profile_library_added_at_idx")
    conn.exec <<-SQL
    CREATE INDEX lightious_items_profile_library_added_at_idx
      ON public.lightious_items (profile_id, added_at DESC)
      WHERE library_visible AND NOT is_short;
    SQL
  end

  private def backfill_lightious_item_authors(conn : PG::Connection)
    begin
      result = conn.exec <<-SQL
      UPDATE public.lightious_items AS item
      SET author_ucid = channel_video.ucid
      FROM public.channel_videos AS channel_video
      WHERE item.author_ucid IS NULL
        AND channel_video.id = item.video_id
        AND channel_video.ucid ~ '^UC[A-Za-z0-9_-]{22}$';
      SQL
      LOGGER.info("ensure_lightious_schema: restored #{result.rows_affected} item channel IDs from channel_videos") if result.rows_affected > 0
    rescue ex
      LOGGER.warn("ensure_lightious_schema: could not backfill item channel IDs from channel_videos: #{ex.message}")
    end

    begin
      result = conn.exec <<-SQL
      UPDATE public.lightious_items AS item
      SET author_ucid = cached.author_ucid
      FROM (
        SELECT
          id AS video_id,
          substring(
            info FROM '"ucid"[[:space:]]*:[[:space:]]*"(UC[A-Za-z0-9_-]{22})"'
          ) AS author_ucid
        FROM public.videos
      ) AS cached
      WHERE item.author_ucid IS NULL
        AND cached.video_id = item.video_id
        AND cached.author_ucid IS NOT NULL;
      SQL
      LOGGER.info("ensure_lightious_schema: restored #{result.rows_affected} item channel IDs from cached videos") if result.rows_affected > 0
    rescue ex
      LOGGER.warn("ensure_lightious_schema: could not backfill item channel IDs from cached videos: #{ex.message}")
    end
  end

  private def ensure_lightious_item_author_constraint(conn : PG::Connection)
    conn.exec <<-SQL
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'lightious_items_author_ucid_check'
          AND conrelid = 'public.lightious_items'::regclass
      ) THEN
        ALTER TABLE public.lightious_items
          ADD CONSTRAINT lightious_items_author_ucid_check
          CHECK (author_ucid IS NULL OR author_ucid ~ '^UC[A-Za-z0-9_-]{22}$');
      END IF;
    END
    $$;
    SQL
  end

  private def ensure_lightious_playlist_name_constraint(conn : PG::Connection)
    conn.exec <<-SQL
    DO $$
    DECLARE
      constraint_definition text;
    BEGIN
      SELECT pg_get_constraintdef(oid)
      INTO constraint_definition
      FROM pg_constraint
      WHERE conname = 'lightious_playlists_name_check'
        AND conrelid = 'public.lightious_playlists'::regclass;

      IF constraint_definition IS NULL OR position('100' IN constraint_definition) = 0 THEN
        ALTER TABLE public.lightious_playlists
          DROP CONSTRAINT IF EXISTS lightious_playlists_name_check;
        ALTER TABLE public.lightious_playlists
          ADD CONSTRAINT lightious_playlists_name_check
          CHECK (octet_length(name) BETWEEN 1 AND 100) NOT VALID;
      END IF;
    END
    $$;
    SQL

    begin
      conn.exec("ALTER TABLE public.lightious_playlists VALIDATE CONSTRAINT lightious_playlists_name_check")
    rescue ex
      # Existing names are not discarded or truncated during an upgrade. The
      # NOT VALID constraint still enforces the 100-byte limit for new writes.
      LOGGER.warn("ensure_lightious_schema: existing playlist names exceed 100 bytes; the new limit applies to future writes: #{ex.message}")
    end
  end

  #
  # Table/enum integrity checks
  #

  def check_enum(enum_name, struct_type = nil)
    return # TODO

    if !PG_DB.query_one?("SELECT true FROM pg_type WHERE typname = $1", enum_name, as: Bool)
      LOGGER.info("check_enum: CREATE TYPE #{enum_name}")

      PG_DB.using_connection do |conn|
        conn.as(PG::Connection).exec_all(File.read("config/sql/#{enum_name}.sql"))
      end
    end
  end

  def check_table(table_name, struct_type = nil)
    # Create table if it doesn't exist
    begin
      PG_DB.exec("SELECT * FROM #{table_name} LIMIT 0")
    rescue ex
      LOGGER.info("check_table: check_table: CREATE TABLE #{table_name}")

      PG_DB.using_connection do |conn|
        conn.as(PG::Connection).exec_all(File.read("config/sql/#{table_name}.sql"))
      end
    end

    return if !struct_type

    struct_array = struct_type.type_array
    column_array = get_column_array(PG_DB, table_name)
    column_types = File.read("config/sql/#{table_name}.sql").match(/CREATE TABLE public\.#{table_name}\n\((?<types>[\d\D]*?)\);/)
      .try &.["types"].split(",").map(&.strip).reject &.starts_with?("CONSTRAINT")

    return if !column_types

    struct_array.each_with_index do |name, i|
      if name != column_array[i]?
        if !column_array[i]?
          new_column = column_types.select(&.starts_with?(name))[0]
          LOGGER.info("check_table: ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
          PG_DB.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
          next
        end

        # Column doesn't exist
        if !column_array.includes? name
          new_column = column_types.select(&.starts_with?(name))[0]
          PG_DB.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
        end

        # Column exists but in the wrong position, rotate
        if struct_array.includes? column_array[i]
          until name == column_array[i]
            new_column = column_types.select(&.starts_with?(column_array[i]))[0]?.try &.gsub("#{column_array[i]}", "#{column_array[i]}_new")

            # There's a column we didn't expect
            if !new_column
              LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]}")
              PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")

              column_array = get_column_array(PG_DB, table_name)
              next
            end

            LOGGER.info("check_table: ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
            PG_DB.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")

            LOGGER.info("check_table: UPDATE #{table_name} SET #{column_array[i]}_new=#{column_array[i]}")
            PG_DB.exec("UPDATE #{table_name} SET #{column_array[i]}_new=#{column_array[i]}")

            LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
            PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")

            LOGGER.info("check_table: ALTER TABLE #{table_name} RENAME COLUMN #{column_array[i]}_new TO #{column_array[i]}")
            PG_DB.exec("ALTER TABLE #{table_name} RENAME COLUMN #{column_array[i]}_new TO #{column_array[i]}")

            column_array = get_column_array(PG_DB, table_name)
          end
        else
          LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
          PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
        end
      end
    end

    return if column_array.size <= struct_array.size

    column_array.each do |column|
      if !struct_array.includes? column
        LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column} CASCADE")
        PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column} CASCADE")
      end
    end
  end

  def get_column_array(db, table_name)
    column_array = [] of String
    PG_DB.query("SELECT * FROM #{table_name} LIMIT 0") do |rs|
      rs.column_count.times do |i|
        column = rs.as(PG::ResultSet).field(i)
        column_array << column.name
      end
    end

    return column_array
  end
end
