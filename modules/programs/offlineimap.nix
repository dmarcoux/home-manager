{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.programs.offlineimap;

  accounts = filter (a: a.offlineimap.enable)
    (attrValues config.accounts.email.accounts);

  toIni = generators.toINI {
    mkKeyValue = key: value:
      let
        value' =
          (if isBool value then lib.hm.booleans.yesNo else toString) value;
      in "${key} = ${value'}";
  };

  # Generates a script to fetch only a specific account.
  #
  # Note, these scripts are not actually created and installed at the
  # moment. It will need some thinking on whether this is a good idea
  # and whether other modules should have some similar functionality.
  #
  # Perhaps have a single tool `email` that wraps the command?
  # Something like
  #
  #     $ email <account name> <program name> <program args>
  genOfflineImapScript = account:
    with account;
    pkgs.writeShellScriptBin "offlineimap-${name}" ''
      exec ${cfg.package}/bin/offlineimap -a${account.name} "$@"
    '';

  accountStr = account:
    with account;
    let
      postSyncHook = optionalAttrs (offlineimap.postSyncHookCommand != "") {
        postsynchook = pkgs.writeShellScriptBin "postsynchook"
          offlineimap.postSyncHookCommand + "/bin/postsynchook";
      };

      localType =
        if account.flavor == "gmail.com" then "GmailMaildir" else "Maildir";

      remoteType = if account.flavor == "gmail.com" then "Gmail" else "IMAP";

      remoteHost =
        optionalAttrs (imap.host != null) { remotehost = imap.host; };

      remotePort =
        optionalAttrs ((imap.port or null) != null) { remoteport = imap.port; };

      ssl = if imap.tls.enable then {
        ssl = true;
        sslcacertfile = toString imap.tls.certificatesFile;
        starttls = imap.tls.useStartTls;
      } else {
        ssl = false;
      };

      remotePassEval =
        let arglist = concatMapStringsSep "," (x: "'${x}'") passwordCommand;
        in optionalAttrs (passwordCommand != null) {
          remotepasseval = ''get_pass("${name}", [${arglist}]).strip(b"\n")'';
        };
    in toIni {
      "Account ${name}" = {
        localrepository = "${name}-local";
        remoterepository = "${name}-remote";
      } // postSyncHook // offlineimap.extraConfig.account;

      "Repository ${name}-local" = {
        type = localType;
        localfolders = maildir.absPath;
      } // offlineimap.extraConfig.local;

      "Repository ${name}-remote" = {
        type = remoteType;
        remoteuser = userName;
      } // remoteHost // remotePort // remotePassEval // ssl
        // offlineimap.extraConfig.remote;
    };

  extraConfigType = with types; attrsOf (either (either str int) bool);

in {
  options = {
    programs.offlineimap = {
      enable = mkEnableOption "OfflineIMAP";

      package = mkPackageOption pkgs "offlineimap" {
        example = ''
          pkgs.offlineimap.overridePythonAttrs ( old: {
            propagatedBuildInputs = old.propagatedBuildInputs
              ++ (with pkgs.python3Packages; [
                requests_oauthlib xdg gpgme]);
          })'';
        extraDescription = "Can be used to specify extensions.";
      };

      pythonFile = mkOption {
        type = types.lines;
        default = ''
          import subprocess

          def get_pass(service, cmd):
              return subprocess.check_output(cmd, )
        '';
        description = ''
          Python code that can then be used in other parts of the
          configuration.
        '';
      };

      extraConfig.general = mkOption {
        type = extraConfigType;
        default = { };
        example = {
          maxage = 30;
          ui = "blinkenlights";
        };
        description = ''
          Extra configuration options added to the
          <option>general</option> section.
        '';
      };

      extraConfig.default = mkOption {
        type = extraConfigType;
        default = { };
        example = { gmailtrashfolder = "[Gmail]/Papierkorb"; };
        description = ''
          Extra configuration options added to the
          <option>DEFAULT</option> section.
        '';
      };

      extraConfig.mbnames = mkOption {
        type = extraConfigType;
        default = { };
        example = literalExpression ''
          {
            filename = "~/.config/mutt/mailboxes";
            header = "'mailboxes '";
            peritem = "'+%(accountname)s/%(foldername)s'";
            sep = "' '";
            footer = "'\\n'";
          }
        '';
        description = ''
          Extra configuration options added to the
          <code>mbnames</code> section.
        '';
      };
    };

    accounts.email.accounts = mkOption {
      type = with types;
        attrsOf (submodule (import ./offlineimap-accounts.nix));
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."offlineimap/get_settings.py".text = cfg.pythonFile;
    xdg.configFile."offlineimap/get_settings.pyc".source = "${
        pkgs.runCommandLocal "get_settings-compile" {
          nativeBuildInputs = [ cfg.package ];
          pythonFile = cfg.pythonFile;
          passAsFile = [ "pythonFile" ];
        } ''
          mkdir -p $out/bin
          cp $pythonFilePath $out/bin/get_settings.py
          python -m py_compile $out/bin/get_settings.py
        ''
      }/bin/get_settings.pyc";

    xdg.configFile."offlineimap/config".text = ''
      # Generated by Home Manager.
      # See https://github.com/OfflineIMAP/offlineimap/blob/master/offlineimap.conf
      # for an exhaustive list of options.
    '' + toIni ({
      general = {
        accounts = concatMapStringsSep "," (a: a.name) accounts;
        pythonfile = "${config.xdg.configHome}/offlineimap/get_settings.py";
        metadata = "${config.xdg.dataHome}/offlineimap";
      } // cfg.extraConfig.general;
    } // optionalAttrs (cfg.extraConfig.mbnames != { }) {
      mbnames = { enabled = true; } // cfg.extraConfig.mbnames;
    } // optionalAttrs (cfg.extraConfig.default != { }) {
      DEFAULT = cfg.extraConfig.default;
    }) + "\n" + concatStringsSep "\n" (map accountStr accounts);
  };
}
