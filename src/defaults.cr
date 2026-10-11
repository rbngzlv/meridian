module Meridian
  module Defaults
    # Keep init and generator defaults on the same pinned Caddy image.
    PROXY_IMAGE = "docker.io/library/caddy:2.11.7-alpine"
  end
end
