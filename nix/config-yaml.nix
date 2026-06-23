{ lib, pkgs }:

let
  yaml = pkgs.formats.yaml { };
in
rec {
  mkConfigYaml = cfg: {
    dataRoot = cfg.dataDir;

    port = cfg.port;
    listen = cfg.listen;
    listenAddress = {
      ipv4 = cfg.listenAddressIPv4;
      ipv6 = cfg.listenAddressIPv6;
    };
    protocol = {
      ipv4 = cfg.protocolIPv4;
      ipv6 = cfg.protocolIPv6;
    };
    dnsPreferIPv6 = cfg.dnsPreferIPv6;
    enableKeepAlive = cfg.enableKeepAlive;
    heartbeatInterval = cfg.heartbeatInterval;

    ssl = {
      enabled = cfg.ssl.enable;
      certPath = cfg.ssl.certPath;
      keyPath = cfg.ssl.keyPath;
      keyPassphrase = cfg.ssl.keyPassphrase;
    };

    whitelistMode = cfg.whitelistMode;
    whitelist = cfg.whitelist;
    whitelistDockerHosts = cfg.whitelistDockerHosts;
    basicAuthMode = cfg.basicAuthMode;
    basicAuthUser = {
      username = cfg.basicAuthUser;
      password = cfg.basicAuthPassword;
    };
    enableCorsProxy = cfg.enableCorsProxy;
    cors = {
      enabled = cfg.cors.enable;
      origin = cfg.cors.origin;
      methods = cfg.cors.methods;
      allowedHeaders = cfg.cors.allowedHeaders;
      exposedHeaders = cfg.cors.exposedHeaders;
      credentials = cfg.cors.credentials;
      maxAge = cfg.cors.maxAge;
    };

    enableUserAccounts = cfg.enableUserAccounts;
    enableDiscreetLogin = cfg.enableDiscreetLogin;
    disableCsrfProtection = cfg.disableCsrf;
    securityOverride = cfg.securityOverride;

    browserLaunch = {
      enabled = cfg.browserLaunch.enable;
      browser = cfg.browserLaunch.browser;
      hostname = cfg.browserLaunch.hostname;
      port = cfg.browserLaunch.port;
      avoidLocalhost = cfg.browserLaunch.avoidLocalhost;
    };

    requestProxy = {
      enabled = cfg.requestProxy.enable;
      url = cfg.requestProxy.url;
      bypass = cfg.requestProxy.bypass;
    };

    logging = {
      enableAccessLog = cfg.logging.enableAccessLog;
      minLogLevel = cfg.logging.minLogLevel;
    };

    rateLimiting = {
      basicAuthMaxAttempts = cfg.rateLimiting.basicAuthMaxAttempts;
      accountsLoginMaxAttempts = cfg.rateLimiting.accountsLoginMaxAttempts;
      accountsRecoverMaxAttempts = cfg.rateLimiting.accountsRecoverMaxAttempts;
    };

    sessionTimeout = cfg.sessionTimeout;

    extensions = {
      enabled = cfg.extensions.enable;
      autoUpdate = cfg.extensions.autoUpdate;
    };

    enableServerPlugins = cfg.enableServerPlugins;
    enableServerPluginsAutoUpdate = cfg.enableServerPluginsAutoUpdate;

    allowKeysExposure = cfg.allowKeysExposure;
    skipContentCheck = cfg.skipContentCheck;

    git.backend = cfg.gitBackend;

    enableDownloadableTokenizers = cfg.enableDownloadableTokenizers;

    promptPlaceholder = cfg.promptPlaceholder;
  }
  // (lib.optionalAttrs (cfg.extraConfig != { }) cfg.extraConfig);

  generateConfigYaml = cfg: yaml.generate "sillytavern-config.yaml" (mkConfigYaml cfg);
}
