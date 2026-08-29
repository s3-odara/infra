-- Adapted from Prosody Community Modules' mod_strict_https by Kim Alvefur
-- and Menel: https://modules.prosody.im/mod_strict_https.html
-- Wrap response writers so module-specific headers cannot override this policy.

module:set_global();

local http_server = require "net.http.server";
local hsts_header = "max-age=63072000; includeSubDomains";

local function protect_response(response)
  if response._http_hsts_protected then
    return;
  end
  response._http_hsts_protected = true;

  for _, method_name in ipairs({ "send", "send_file", "write_headers" }) do
    local original = response[method_name];
    if original then
      response[method_name] = function (self, ...)
        self.headers.strict_transport_security = hsts_header;
        return original(self, ...);
      end;
    end
  end

  response.headers.strict_transport_security = hsts_header;
end

module:wrap_object_event(http_server._events, false, function (handlers, event_name, event_data)
  local response = event_data and event_data.response;

  -- A response without a request is Prosody's emergency 500 path.
  if response and (not response.request or response.request.secure) then
    protect_response(response);
  end

  return handlers(event_name, event_data);
end);
