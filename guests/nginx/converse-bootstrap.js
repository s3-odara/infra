import "/converse.min.js";

converse.initialize({
  allow_registration: false,
  auto_away: 300,
  auto_reconnect: true,
  auto_xa: 1800,
  locked_domain: "xmpp.odarah.org",
  muc_domain: "conference.xmpp.odarah.org",
  view_mode: "fullscreen",
  websocket_url: "wss://xmpp.odarah.org/xmpp-websocket",
});
