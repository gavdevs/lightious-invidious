require "spectator"
require "../../../src/invidious/lightious/pairing"
require "../../../src/invidious/lightious/device_authorization"

Spectator.describe Invidious::Lightious::DeviceAuthorization do
  describe ".bearer_digest" do
    it "accepts only a canonical Lightious device bearer" do
      bearer = "lpt_device_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      expected = Invidious::Lightious::Pairing.device_bearer_digest(bearer)

      expect(described_class.bearer_digest("Bearer #{bearer}")).to eq(expected)
      expect(described_class.bearer_digest("bearer #{bearer}")).to eq(expected)
    end

    it "rejects missing, ambiguous, malformed, and non-device credentials" do
      bearer = "lpt_device_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      expect(described_class.bearer_digest(nil)).to be_nil
      expect(described_class.bearer_digest(bearer)).to be_nil
      expect(described_class.bearer_digest("Basic #{bearer}")).to be_nil
      expect(described_class.bearer_digest("Bearer  #{bearer}")).to be_nil
      expect(described_class.bearer_digest("Bearer #{bearer} ")).to be_nil
      expect(described_class.bearer_digest("Bearer lpt_poll_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")).to be_nil
    end
  end

  describe ".request_access" do
    it "allows only the Lightious browser bootstrap, assets, thumbnails, and health publicly" do
      public_routes = {
        {"GET", "/lightious"},
        {"GET", "/lightious/library"},
        {"GET", "/lightious/playlists/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {"GET", "/lightious/channels/UC_x5XG1OV2P6uZZ5FSM9Ttw"},
        {"POST", "/lightious/pair"},
        {"POST", "/lightious/videos/bulk"},
        {"POST", "/lightious/channels/bulk"},
        {"POST", "/lightious/channels/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/policy"},
        {"POST", "/lightious/channels/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/delete"},
        {"POST", "/lightious/channels/UC_x5XG1OV2P6uZZ5FSM9Ttw/add"},
        {"POST", "/lightious/channels/UC_x5XG1OV2P6uZZ5FSM9Ttw/videos/add"},
        {"POST", "/lightious/playlists/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/search/add"},
        {"POST", "/lightious/playlists/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/items/remove"},
        {"GET", "/login"},
        {"POST", "/login"},
        {"POST", "/signout"},
        {"GET", "/toggle_theme"},
        {"GET", "/css/lightious.css"},
        {"GET", "/vi/dQw4w9WgXcQ/mqdefault.jpg"},
        {"GET", "/api/v1/stats"},
        {"POST", "/api/lightious/v1/pairings"},
        {"GET", "/api/lightious/v1/pairings/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        {"POST", "/api/lightious/v1/pairings/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/activate"},
        {"POST", "/lightious/videos/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/policy"},
        {"POST", "/lightious/devices/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/revoke"},
      }

      public_routes.each do |method, path|
        expect(described_class.request_access(method, path)).to eq(
          Invidious::Lightious::DeviceAuthorization::RequestAccess::Public
        )
      end
    end

    it "requires an active device bearer for every non-bootstrap device API" do
      protected_routes = {
        "/api/lightious/v1/sync",
        "/api/lightious/v1/search",
        "/api/lightious/v1/popular",
        "/api/lightious/v1/feed",
        "/api/lightious/v1/history",
        "/api/lightious/v1/videos/dQw4w9WgXcQ",
        "/api/lightious/v1/channels/UC_x5XG1OV2P6uZZ5FSM9Ttw/videos",
        "/api/lightious/v1/channels/UC_x5XG1OV2P6uZZ5FSM9Ttw/search",
        "/api/lightious/v1/future-endpoint",
      }

      protected_routes.each do |path|
        expect(described_class.request_access("GET", path)).to eq(
          Invidious::Lightious::DeviceAuthorization::RequestAccess::DeviceBearer
        )
      end
    end

    it "routes media only through a signed capability and denies upstream surfaces" do
      expect(described_class.request_access("GET", "/api/lightious/v1/media")).to eq(
        Invidious::Lightious::DeviceAuthorization::RequestAccess::MediaCapability
      )
      expect(described_class.request_access("OPTIONS", "/api/lightious/v1/media")).to eq(
        Invidious::Lightious::DeviceAuthorization::RequestAccess::Public
      )

      denied_routes = {
        "/",
        "/lightiousevil",
        "/lightious/future-route",
        "/lightious/playlists/short",
        "/lightious/playlists/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/trailing",
        "/lightious/channels/uc_x5XG1OV2P6uZZ5FSM9Ttw",
        "/lightious/channels/UC-short",
        "/lightious/channels/UC_x5XG1OV2P6uZZ5FSM9Ttw/trailing",
        "/watch?v=dQw4w9WgXcQ",
        "/search?q=music",
        "/api/v1/search?q=music",
        "/api/v1/videos/dQw4w9WgXcQ",
        "/api/v1/auth/feed",
        "/videoplayback",
        "/latest_version",
        "/companion/player",
        "/api/manifest/dash/id/dQw4w9WgXcQ",
        "/sb/i/dQw4w9WgXcQ/storyboard3_L2/M0.jpg",
      }

      denied_routes.each do |path|
        expect(described_class.request_access("GET", path.split('?', 2)[0])).to eq(
          Invidious::Lightious::DeviceAuthorization::RequestAccess::Deny
        )
      end

      expect(described_class.request_access("PUT", "/lightious/library")).to eq(
        Invidious::Lightious::DeviceAuthorization::RequestAccess::Deny
      )
      expect(described_class.request_access("POST", "/lightious/channels/UC-short/add")).to eq(
        Invidious::Lightious::DeviceAuthorization::RequestAccess::Deny
      )
      expect(described_class.request_access("POST", "/lightious/playlists/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/items")).to eq(
        Invidious::Lightious::DeviceAuthorization::RequestAccess::Deny
      )
    end
  end
end
