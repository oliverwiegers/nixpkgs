{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.poweradmin;
  fpm = config.services.phpfpm.pools.poweradmin;
  localDB = cfg.database.host == "localhost";
  user = cfg.database.username;

  phpPackage = pkgs.php.withExtensions (
    { enabled, all }: enabled ++ with all; lib.lists.concatLists [
      [
        intl
        gettext
        openssl
        filter
        tokenizer
        xml
        pdo
      ]
      (lib.lists.optionals (cfg.database.type == "postgres") [
        pdo_pgsql
      ])
      (lib.lists.optionals (cfg.database.type == "mysql") [
        pdo_mysql
      ])
      (lib.lists.optionals cfg.ldap.enable [
        ldap
      ])
    ]
  );
in
{
  options.services.poweradmin = { enable = lib.mkEnableOption "poweradmin";
    package = lib.mkPackageOption pkgs "poweradmin";

    hostName = lib.mkOption {
      type = lib.types.str;
      example = "webmail.example.com";
      description = "Hostname to use for the nginx vhost.";
    };

    database = {
      type = lib.mkOption {
        # TODO: Think about it. We could support sqlite as well. But we can't put the DB into docroot, because in the current setup the docroot resides in the nix store.
        type = lib.types.enum [ "postgres" "mysql" ];
        default = "mysql";
        description = "Database type PowerDNS is using. Possible values are `["postgres" "mysql"]`.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Host housing the PowerDNS database."
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "powerdns";
        description = "PowerDNS database name.";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "poweradmin";
        description = "PowerDNS database user."
      };

      password = lib.mkOption {
        type = lib.types.str;
        description = "PowerDNS database password.";
        default = "";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "File containing PowerDNS database password.";
      };

      poweradminDBUserPassword = lib.mkOption {
        type = lib.types.str;
        description = "Poweradmin user password for PowerDNS database password.";
        default = "";
      };

      poweradminDBUserPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = "File containing poweradmin user password for PowerDNS database.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = [];
    assertions = [];

    # FIXME: Auto genereate the random string.
    environment.etc."poweradmin/settings.php".text = ''
      <?php
      /**
       * Poweradmin Custom Settings Configuration File
       */

      return [
          /**
           * Database Settings
           */
          'database' => [
              'host' => '${cfg.database.host}',
              'user' => '${cfg.database.username}',
              'password' => '${cfg.databse.password}',
              'name' => '${cfg.databse.name}',
              'type' => '${cfg.databse.type}',
          ],

          /**
           * Security Settings
           */
          'security' => [
              'session_key' => 'generate_a_random_string_here',
          ],
      ];
    '';

    # TODO: Check https://github.com/poweradmin/poweradmin/blob/master/nginx.conf.example and implemente missing things.
    services.nginx = lib.mkIf cfg.configureNginx {
      enable = true;
      virtualHosts = {
        ${cfg.hostName} = {
          forceSSL = lib.mkDefault true;
          enableACME = lib.mkDefault true;
          root = cfg.package;
          locations."/" = {
            index = "index.php";
            priority = 1100;
            extraConfig = ''
              add_header Cache-Control 'public, max-age=604800, must-revalidate';
            '';
          };
          locations."~ ^/(SQL|bin|config|logs|temp|vendor)/" = {
            priority = 3110;
            extraConfig = ''
              return 404;
            '';
          };
          locations."~ ^/(CHANGELOG.md|INSTALL|LICENSE|README.md|SECURITY.md|UPGRADING|composer.json|composer.lock)" =
            {
              priority = 3120;
              extraConfig = ''
                return 404;
              '';
            };
          locations."~* \\.php(/|$)" = {
            priority = 3130;
            extraConfig = ''
              fastcgi_pass unix:${fpm.socket};
              fastcgi_param PATH_INFO $fastcgi_path_info;
              fastcgi_split_path_info ^(.+\.php)(/.+)$;
              include ${config.services.nginx.package}/conf/fastcgi.conf;
            '';
          };
        };
      };
    };

    users = lib.mkIf localDB {
      groups.${user} = {};

      users.${user} = {
        group = user;
        isSystemUser = true;
        createHome = false;
      };
    };


    services.phpfpm.pools.poweradmin = {
      user = if localDB then user else "nginx";
      phpOptions = ''
        error_log = '/dev/stderr'
        log_errors = on
      '';
      settings = lib.mapAttrs (name: lib.mkDefault) {
        "listen.owner" = "nginx";
        "listen.group" = "nginx";
        "listen.mode" = "0660";
        "pm" = "dynamic";
        "pm.max_children" = 75;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 1;
        "pm.max_spare_servers" = 20;
        "pm.max_requests" = 500;
        "catch_workers_output" = true;
      };
      phpPackage = phpPackage;
    };

    systemd.services.phpfpm-poweradmin = {
      after = [ "poweradmin-setup.service" ];

      restartTriggers = [
        config.environment.etc."poweradmin/config/settings.php".source
      ];
    };

    systemd.services.poweradmin-setup = lib.mkMerge [
      (lib.mkIf (cfg.database.host == "localhost" && cfg.database.type == "postgres") {
        requires = [ "postgresql.target" ];
        after = [ "postgresql.target" ];
      })

      (lib.mkIf (cfg.database.host == "localhost" && cfg.database.type == "mysql") {
        requires = [ "mysql.target" ];
        after = [ "mysql.target" ];
      })

      {
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = env;

        script =
          let
            sqlQuery = "${lib.optionalString (!localDB) "PGPASSFILE=${cfg.database.passwordFile}"} psql ${
              lib.optionalString (!localDB) "-h ${cfg.database.host} -U ${cfg.database.username} "
            } ${cfg.database.dbname}";
          in
          # FIXME: This setup currently only works when the database is on the same host.
          # FIXME: For remote setup correct password and username must be provided for the a DB admin user.
          (lib.stings.concatLines
            (lib.lists.concatLists [
              (lib.lists.optionals (config.services.poweradmin.database.type == "postgres") [
                "sudo -u root pgsql --host=${cfg.database.host} --username=postgres --command='CREATE USER poweradmin WITH PASSWORD ''\'${cfg.poweradminDBUserPassword}''\'';"
                "sudo -u root pgsql --host=${cfg.database.host} --username=postgres --command='GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO poweradmin;'"
                "sudo -u root pgsql --host=${cfg.database.host} --username=postgres --dbname=${cfg.database.name} --file=${cfg.package}/sql/poweradmin-pgsql-db-structure.sql"
              ]
            ])

            (lib.lists.concatLists [
              (lib.lists.optionals (config.services.poweradmin.database.type == "mysql") [
                "mysql --user=root --execute='CREATE USER ''\'poweradmin''\'@''\'${cfg.database.host}''\' INDENTIFIED BY ''\'${cfg.poweradminDBUserPassword}''\'';"
                "mysql --user=root --execute='GRANT SELECT, INSERT, UPDATE, DELETE ON powerdns.* TO ''\'poweradmin''\'@''\'${cfg.database.host}''\'';"
                "mysql --user=root --execute='FLUSH PRIVILEGES;'"
                "mysql --user=root --database=powerdns -f ${cfg.package}/sql/poweradmin-mysql-db-structure.sql"
              ]
            ])
          );
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "poweradmin";
          User = "root";
          StateDirectoryMode = "0700";
        };
      }
    ];
  };
}
