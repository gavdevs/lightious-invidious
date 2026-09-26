require "spectator"
require "kemal"
require "../../../src/invidious/helpers/logger"
require "db"
require "pg"

LOGGER = Invidious::LogHandler.new(IO::Memory.new, LogLevel::Off, use_color: false)
PG_DB  = DB.open(ENV["LIGHTIOUS_DATABASE_SPEC_URL"])

require "../../../src/invidious/lightious/library_destination"
require "../../../src/invidious/database/lightious"
require "../../../src/invidious/database/base"

alias LightiousDatabase = Invidious::Database::Lightious
alias LightiousDestination = Invidious::Lightious::LibraryDestination

private def lightious_item_input(id : String, video_id : String)
  LightiousDatabase::ItemInput.new(
    item_id: id,
    video_id: video_id,
    title: "Video #{video_id}",
    author: "Test channel",
    author_ucid: "UCTTTTTTTTTTTTTTTTTTTTTT",
    length_seconds: 60_i64,
    thumbnail_url: nil,
    playback_policy: "listen_only",
  )
end

Spectator.describe Invidious::Database::Lightious do
  it "upgrades legacy feed settings during ordinary startup and preserves pairings on repeat starts" do
    # Exercise the actual startup schema path, without --migrate. Roll back the
    # legacy schema fixture afterwards so other integration fixtures survive.
    PG_DB.transaction do |transaction|
      conn = transaction.connection.as(PG::Connection)
      conn.exec_all <<-SQL
      ALTER TABLE public.lightious_profiles
        DROP COLUMN channel_feed_limit,
        DROP COLUMN hide_watched,
        DROP CONSTRAINT lightious_profiles_mode_check;
      ALTER TABLE public.lightious_profiles
        ALTER COLUMN mode SET DEFAULT 'explore',
        ADD CONSTRAINT lightious_profiles_mode_check CHECK (mode IN ('explore', 'focused')) NOT VALID;
      INSERT INTO users (email) VALUES ('lightious-ci-startup-explore'), ('lightious-ci-startup-focused');
      INSERT INTO lightious_profiles (id, invidious_user_email, mode, revision) VALUES
        ('ci-startup-explore', 'lightious-ci-startup-explore', 'explore', 7),
        ('ci-startup-focused', 'lightious-ci-startup-focused', 'focused', 8);
      INSERT INTO lightious_devices (id, profile_id, bearer_digest, label) VALUES
        ('ci-startup-device', 'ci-startup-explore', 'ci-startup-device-digest', 'Existing phone');
      INSERT INTO lightious_pairings (
        id, user_code_digest, poll_secret_digest, device_bearer_digest, device_label,
        state, claimed_profile_id, expires_at
      ) VALUES (
        'ci-startup-pairing', 'ci-startup-code-digest', 'ci-startup-poll-digest',
        'ci-startup-pairing-device-digest', 'Pairing phone', 'claimed',
        'ci-startup-explore', now() + interval '10 minutes'
      );
      SQL

      Invidious::Database.ensure_lightious_schema(conn)
      query = "SELECT mode, revision, channel_feed_limit, hide_watched, updated_at FROM lightious_profiles WHERE id = $1"
      explore = conn.query_one(query, "ci-startup-explore", as: {String, Int64, Int32, Bool, Time})
      focused = conn.query_one(query, "ci-startup-focused", as: {String, Int64, Int32, Bool, Time})
      expect({explore[0], explore[1], explore[2], explore[3]}).to eq({"library", 8_i64, 3, true})
      expect({focused[0], focused[1], focused[2], focused[3]}).to eq({"focused", 8_i64, 3, true})
      expect(
        conn.query_one(
          "SELECT column_default FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'lightious_profiles' AND column_name = 'mode'",
          as: String,
        )
      ).to eq("'focused'::text")

      Invidious::Database.ensure_lightious_schema(conn)
      expect(conn.query_one(query, "ci-startup-explore", as: {String, Int64, Int32, Bool, Time})).to eq(explore)
      expect(conn.query_one(query, "ci-startup-focused", as: {String, Int64, Int32, Bool, Time})).to eq(focused)

      conn.exec("UPDATE lightious_profiles SET channel_feed_limit = 5, hide_watched = false WHERE id = 'ci-startup-explore'")
      library = conn.query_one(query, "ci-startup-explore", as: {String, Int64, Int32, Bool, Time})
      Invidious::Database.ensure_lightious_schema(conn)
      expect(conn.query_one(query, "ci-startup-explore", as: {String, Int64, Int32, Bool, Time})).to eq(library)
      expect(
        conn.query_one(
          "SELECT profile_id, bearer_digest, revoked_at IS NULL FROM lightious_devices WHERE id = 'ci-startup-device'",
          as: {String, String, Bool},
        )
      ).to eq({"ci-startup-explore", "ci-startup-device-digest", true})
      expect(
        conn.query_one(
          "SELECT claimed_profile_id, state, poll_secret_digest, device_bearer_digest FROM lightious_pairings WHERE id = 'ci-startup-pairing'",
          as: {String, String, String, String},
        )
      ).to eq({"ci-startup-explore", "claimed", "ci-startup-poll-digest", "ci-startup-pairing-device-digest"})
      transaction.rollback
    end
  end

  it "persists feed settings and revises only changed experience settings" do
    now = Time.utc
    account = "lightious-ci-feed-settings"
    profile_id = "lightious-ci-feed-profile"
    PG_DB.exec("DELETE FROM users WHERE email = $1", account)
    begin
      PG_DB.exec("INSERT INTO users (email) VALUES ($1)", account)
      profile = described_class.ensure_profile(account, profile_id, now)
      expect({profile.mode, profile.channel_feed_limit, profile.hide_watched}).to eq({"focused", 3, true})

      unchanged = described_class.update_experience(account, "focused", 3, true, now).not_nil!
      expect(unchanged.revision).to eq(profile.revision)
      updated = described_class.update_experience(account, "library", 5, false, now + 1.second).not_nil!
      expect(updated.revision).to eq(profile.revision + 1)
      expect({updated.mode, updated.channel_feed_limit, updated.hide_watched}).to eq({"library", 5, false})
      expect(described_class.profile_for_id(profile_id)).to eq(updated)
      expect(described_class.profile_for_account(account)).to eq(updated)
      expect(described_class.ensure_profile(account, "unused-id", now)).to eq(updated)

      expect { described_class.update_experience(account, "explore", 3, true, now) }.to raise_error(PQ::PQError)
      expect { described_class.update_experience(account, "focused", 0, true, now) }.to raise_error(PQ::PQError)
      expect { described_class.update_experience(account, "focused", 6, true, now) }.to raise_error(PQ::PQError)
      expect(described_class.profile_for_id(profile_id)).to eq(updated)
    ensure
      PG_DB.exec("DELETE FROM users WHERE email = $1", account)
    end
  end

  it "keeps library, channel, and playlist organization independent" do
    now = Time.utc
    account = "lightious-ci-data-model"
    profile_id = "lightious-ci-data-profile"
    playlist_one = "lightious-ci-data-playlist-one"
    playlist_two = "lightious-ci-data-playlist-two"
    playlist_three = "lightious-ci-data-playlist-three"

    PG_DB.exec("DELETE FROM users WHERE email = $1", account)
    begin
      PG_DB.exec("INSERT INTO users (email) VALUES ($1)", account)
      profile = described_class.ensure_profile(account, profile_id, now)
      expect(profile.id).to eq(profile_id)
      expect(described_class.create_playlist(account, playlist_one, "One", now)).to be_true
      expect(described_class.create_playlist(account, playlist_two, "Two", now)).to be_true
      expect(described_class.create_playlist(account, playlist_three, "Three", now)).to be_true

      video_one = lightious_item_input("lightious-ci-data-item-one", "AAAAAAAAAAA")
      video_two = lightious_item_input("lightious-ci-data-item-two", "BBBBBBBBBBB")
      video_three = lightious_item_input("lightious-ci-data-item-three", "CCCCCCCCCCC")

      expect(
        described_class.save_video_destination(
          account,
          video_one,
          LightiousDestination::LibraryOnly,
          now,
        )
      ).to be_true
      expect(
        described_class.save_video_destination(
          account,
          video_two,
          LightiousDestination::PlaylistOnly,
          now,
          playlist_one,
        )
      ).to be_true
      expect(
        described_class.save_video_destination(
          account,
          video_three,
          LightiousDestination::LibraryAndPlaylist,
          now,
          playlist_one,
        )
      ).to be_true

      visible_ids = described_class.visible_items_for_profile(profile_id).map(&.video_id).sort
      expect(visible_ids).to eq(["AAAAAAAAAAA", "CCCCCCCCCCC"])
      expect(described_class.items_for_profile(profile_id).map(&.video_id).sort).to eq(visible_ids)
      expect(described_class.all_items_for_profile(profile_id).size).to eq(3)
      expect(described_class.items_for_playlist(playlist_one, profile_id).map(&.video_id)).to eq([
        "BBBBBBBBBBB",
        "CCCCCCCCCCC",
      ])
      expect(described_class.item_for_video(profile_id, "BBBBBBBBBBB").try(&.library_visible)).to be_false
      expect(described_class.playback_policy_for(profile_id, "BBBBBBBBBBB", nil)).to eq("listen_only")
      expect(described_class.channels_for_profile(profile_id)).to be_empty

      # Playlist-only placement adds membership but never hides an item that
      # was already selected for the top-level library.
      expect(
        described_class.save_video_destination(
          account,
          video_one,
          LightiousDestination::PlaylistOnly,
          now,
          playlist_one,
        )
      ).to be_true
      expect(described_class.item_for_video(profile_id, "AAAAAAAAAAA").try(&.library_visible)).to be_true

      # Hidden items survive until their final playlist membership disappears.
      hidden_two = described_class.item_for_video(profile_id, "BBBBBBBBBBB").not_nil!
      expect(described_class.add_playlist_items(account, playlist_two, [hidden_two.id], now)).to eq(1)
      expect(described_class.remove_playlist_item(account, playlist_one, hidden_two.id, now)).to be_true
      expect(described_class.item_for_video(profile_id, "BBBBBBBBBBB")).not_to be_nil
      expect(described_class.remove_playlist_item(account, playlist_two, hidden_two.id, now)).to be_true
      expect(described_class.item_for_video(profile_id, "BBBBBBBBBBB")).to be_nil

      # Removing top-level access preserves playlist membership and playback
      # authorization, then final membership removal cleans the hidden orphan.
      combined = described_class.item_for_video(profile_id, "CCCCCCCCCCC").not_nil!
      expect(described_class.remove_item_from_library(account, combined.id, now)).to be_true
      expect(described_class.item_for_video(profile_id, "CCCCCCCCCCC").try(&.library_visible)).to be_false
      expect(described_class.items_for_playlist(playlist_one, profile_id).map(&.video_id)).to contain("CCCCCCCCCCC")
      expect(described_class.playback_policy_for(profile_id, "CCCCCCCCCCC", nil)).to eq("listen_only")
      expect(described_class.remove_playlist_item(account, playlist_one, combined.id, now)).to be_true
      expect(described_class.item_for_video(profile_id, "CCCCCCCCCCC")).to be_nil

      video_four = lightious_item_input("lightious-ci-data-item-four", "DDDDDDDDDDD")
      saved = described_class.save_videos_destination(
        account,
        [video_four, video_four],
        LightiousDestination::LibraryOnly,
        now,
      )
      expect(saved.try(&.items_saved)).to eq(1)
      visible_item_ids = described_class.visible_items_for_profile(profile_id).map(&.id)
      expect(
        described_class.bulk_update_item_policy(
          account,
          visible_item_ids,
          "watch_and_listen",
          now,
        )
      ).to eq(2)

      expect(
        described_class.upsert_channel(
          account,
          "lightious-ci-data-channel-one",
          "UCAAAAAAAAAAAAAAAAAAAAAA",
          "Channel one",
          nil,
          "listen_only",
          now,
        )
      ).to be_true
      expect(
        described_class.upsert_channel(
          account,
          "lightious-ci-data-channel-two",
          "UCBBBBBBBBBBBBBBBBBBBBBB",
          "Channel two",
          nil,
          "listen_only",
          now,
        )
      ).to be_true
      channel_ids = described_class.channels_for_profile(profile_id).map(&.id)
      expect(
        described_class.bulk_update_channel_policy(
          account,
          channel_ids,
          "watch_and_listen",
          now,
        )
      ).to eq(2)

      # The explicit visibility upsert supports atomic destination workflows;
      # cleanup repairs a hidden row if membership creation never follows.
      expect(
        described_class.upsert_item(
          account: account,
          item_id: "lightious-ci-data-item-five",
          video_id: "EEEEEEEEEEE",
          title: "Orphan",
          author: "Test channel",
          author_ucid: nil,
          length_seconds: 1_i64,
          thumbnail_url: nil,
          playback_policy: "listen_only",
          library_visible: false,
          now: now,
        )
      ).to be_true
      expect(described_class.playback_policy_for(profile_id, "EEEEEEEEEEE", nil)).to be_nil
      expect(described_class.cleanup_hidden_orphans(account, now)).to eq(1)
      expect(described_class.item_for_video(profile_id, "EEEEEEEEEEE")).to be_nil

      video_six = lightious_item_input("lightious-ci-data-item-six", "FFFFFFFFFFF")
      expect(
        described_class.save_video_destination(
          account,
          video_six,
          LightiousDestination::PlaylistOnly,
          now,
          playlist_three,
        )
      ).to be_true
      expect(described_class.delete_playlist(account, playlist_three, now)).to be_true
      expect(described_class.item_for_video(profile_id, "FFFFFFFFFFF")).to be_nil

      video_seven = lightious_item_input("lightious-ci-data-item-seven", "GGGGGGGGGGG")
      expect(
        described_class.save_video_destination(
          account,
          video_seven,
          LightiousDestination::PlaylistOnly,
          now,
          "missing-playlist",
        )
      ).to be_false
      expect(described_class.item_for_video(profile_id, "GGGGGGGGGGG")).to be_nil
    ensure
      PG_DB.exec("DELETE FROM users WHERE email = $1", account)
    end
  end
end
