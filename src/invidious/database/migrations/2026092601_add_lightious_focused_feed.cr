module Invidious::Database::Migrations
  class AddLightiousFocusedFeed < Migration
    version 2026092601

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      ALTER TABLE public.lightious_profiles
        ADD COLUMN IF NOT EXISTS channel_feed_limit integer NOT NULL DEFAULT 3,
        ADD COLUMN IF NOT EXISTS hide_watched boolean NOT NULL DEFAULT true;
      SQL

      conn.exec <<-SQL
      ALTER TABLE public.lightious_profiles
        DROP CONSTRAINT IF EXISTS lightious_profiles_mode_check,
        DROP CONSTRAINT IF EXISTS lightious_profiles_channel_feed_limit_check;
      SQL

      conn.exec <<-SQL
      UPDATE public.lightious_profiles
      SET mode = 'library', revision = revision + 1, updated_at = now()
      WHERE mode = 'explore';
      SQL

      conn.exec <<-SQL
      ALTER TABLE public.lightious_profiles
        ADD CONSTRAINT lightious_profiles_mode_check CHECK (mode IN ('library', 'focused')),
        ADD CONSTRAINT lightious_profiles_channel_feed_limit_check CHECK (channel_feed_limit BETWEEN 1 AND 5);
      SQL
    end
  end
end
