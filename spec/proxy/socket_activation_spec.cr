require "../spec_helper"

describe "Caddy socket activation" do
  it "assigns TCP HTTP, TCP HTTPS and UDP HTTPS in stable descriptor order" do
    generator = Meridian::Quadlet::Generator.new(load_config(FULL_CONFIG))
    unit = generator.proxy_socket_file
    unit.should contain("ListenStream=80\nListenStream=443\nListenDatagram=443\n")
    unit.should contain("BindIPv6Only=both")
    unit.should contain("Accept=no")
    unit.should contain("Service=meridian-caddy.service")
    unit.should contain("WantedBy=sockets.target")
    generator.proxy_container_file.should_not contain("PublishPort")
  end

  it "uses custom host ports without changing Caddy's logical HTTP/HTTPS ports" do
    config = <<-YAML
      service: myapp
      image: example.com/myapp
      servers:
        web:
          hosts: [192.168.1.10]
          proxy:
            host: example.com
      proxy:
        http_port: 8080
        https_port: 8443
      YAML
    generator = Meridian::Quadlet::Generator.new(load_config(config))
    generator.proxy_socket_file.should contain("ListenStream=8080\nListenStream=8443\nListenDatagram=8443")
    generator.proxy_caddyfile.should_not contain("http_port 8080")
  end
end
