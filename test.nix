let
  pkgs = import <nixpkgs> {
    overlays = [
      (self: super: {
        bird = super.bird.overrideAttrs ({ nativeBuildInputs ? [ ], configureFlags ? [ ], ... }: {
          nativeBuildInputs = nativeBuildInputs ++ [ pkgs.autoreconfHook ];
          configureFlags = configureFlags ++ [ "--enable-debug" ];
          src = super.nix-gitignore.gitignoreSource [ "result" "test.nix" ] ./.;
          debugInfo = true;
        });

        #babeld = super.babeld.overrideAttrs (_: {
        #  src = super.fetchFromGitHub {
        #    owner = "jech";
        #    repo = "babeld";
        #    rev = "046271a9066e86b909b21f55ac736675cd64c17a";
        #    sha256 = "0cnn5gshwv4hx46bchydy66f6bfpczps108bmyp8d996cy7hiwyw";
        #    fetchSubmodules = true;
        #  };
        #});
      })
    ];
  };
  inherit (pkgs) lib;
  common = { pkgs, ... }: {
    networking.useDHCP = false;
    environment.systemPackages = [ pkgs.tcpdump pkgs.gdb pkgs.termshark ];
    programs.mtr.enable = true;
    networking.firewall.enable = false;
    networking.interfaces.eth0 = {
      ipv4.addresses = lib.mkForce [ ];
      ipv6.addresses = lib.mkForce [ ];
    };
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = lib.mkForce 1;
      "net.ipv6.conf.all.forwarding" = lib.mkForce 1;
    };
  };

  birdCommon = { pkgs, ... }: {
    imports = [ common ];
    services.bird2 = {
      enable = true;
      config = ''
        #debug protocols all;
        protocol device {
          scan time 60;
        };

        protocol direct {
          ipv4;
          ipv6;
          interface "*";
        };

        protocol kernel k4 {
          ipv4 {
            import none;
            export all;
          };
        };

        protocol kernel k6 {
          ipv6 {
            import none;
            export all;
          };
        };

        protocol babel {
          randomize router id yes;
          interface "eth1", "eth2" { type wired; };
          ipv4 {
            export filter {
              accept;
            };
          };
          ipv6 {};
        };
      '';
    };
  };
in
  pkgs.nixosTest {
    name = "foo";
  nodes = {
    bird1 = {
      imports = [ birdCommon ];
      virtualisation.vlans = [ 1 ];
      networking.interfaces.lo.ipv4.addresses = lib.mkForce [{ address = "192.168.123.1"; prefixLength = 24; }];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [{ address = "10.0.0.1"; prefixLength = 24; }];
      services.bird2.config = ''
        router id 1.1.1.1;
        protocol static {
          ipv4 {};
          route 172.20.199.0/24 blackhole;
        };
      '';
    };

    bird2 = {
      imports = [ birdCommon ];
      virtualisation.vlans = [ 1 2 ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [{ address = "10.0.0.2"; prefixLength = 24; }];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth2.ipv6.addresses = lib.mkForce [{ address = "fe80::2"; prefixLength = 64; }];
      services.bird2.config = ''
        router id 1.1.1.2;
      '';
    };

    babeld1 = {
      imports = [ common ];
      virtualisation.vlans = [ 2 3 ];
      networking.interfaces = {
        eth1.ipv4.addresses = lib.mkForce [ ];
        eth1.ipv6.addresses = lib.mkForce [{ address = "fe80::3"; prefixLength = 64; }];
        eth2.ipv4.addresses = lib.mkForce [{ address = "10.1.0.1"; prefixLength = 24; }];
        eth2.ipv6.addresses = lib.mkForce [ ];
      };
      services.babeld = {
        enable = true;
        interfaces = {
          "eth1" = {
            v4-via-v6 = true;
          };
          "eth2" = {
            v4-via-v6 = true;
          };
        };
        extraConfig = ''
          in allow
          #debug 3
        '';
      };
    };
    babeld2 = {
      imports = [ common ];
      virtualisation.vlans = [ 3 ];
      networking.interfaces = {
        lo.ipv4.addresses = lib.mkForce [{ address = "192.168.126.1"; prefixLength = 24; }];
        eth1.ipv4.addresses = lib.mkForce [{ address = "10.1.0.2"; prefixLength = 24; }];
        eth1.ipv6.addresses = lib.mkForce [ ];
      };
      services.babeld = {
        enable = true;
        interfaces = {
          "eth1" = {
            v4-via-v6 = true;
          };
        };
        extraConfig = ''
          in allow
          #debug 3
        '';
      };
    };
  };
  testScript = ''
    start_all()
    bird1.wait_for_unit("bird2.service")
    bird2.wait_for_unit("bird2.service")
    babeld1.wait_for_unit("babeld.service")
    babeld2.wait_for_unit("babeld.service")

    with subtest("the servers should reach their neighbors"):
        bird1.wait_until_succeeds("ping -c 2 10.0.0.2")
        bird2.wait_until_succeeds("ping -c 2 fe80::3%eth2")
        babeld1.wait_until_succeeds("ping -c 2 10.1.0.2")

    with subtest("bird1 should be able to reach babeld2"):
        bird1.wait_until_succeeds("ping -c 2 192.168.126.1")

        # from here on we *know* that routes have propagated
        bird1.succeed("ping -c 2 10.1.0.2")

    with subtest("Verify that the routes are set up"):
        result = bird1.succeed("ip route get 192.168.126.1")
        print(result)
        assert "via 10.0.0.2" in result
        result = bird2.succeed("ip route get 192.168.126.1")
        print(result)
        assert "via inet6 fe80::3" in result
        result = babeld1.succeed("ip route get 192.168.126.1")
        print(result)
        assert "via 10.1.0.2" in result
  '';
}
