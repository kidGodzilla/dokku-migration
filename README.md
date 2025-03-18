# Dokku Migration Tool

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A command-line tool for easily migrating Dokku applications and databases between servers.

## Features

- 🚀 **Single-Command Installation**: Get up and running with a single curl command
- 🔄 **Complete Migration**: Migrate entire Dokku environments or select specific apps
- 🧩 **Modular Design**: Run individual steps or the complete migration process
- ⚙️ **Flexible Configuration**: Configure via file or command-line arguments
- 🔒 **Secure**: Uses SSH keys for secure server access
- 📊 **Comprehensive**: Transfers apps, databases, config, domains, and volumes
- 🧠 **Smart Defaults**: Sensible defaults with the ability to override

## Quick Start

### Installation

```bash
curl -fsSL https://raw.githubusercontent.com/pedropaf/dokku-migration/main/install.sh | bash
```

This will:
1. Install the tool in `~/.dokku-migration`
2. Create a symlink in `/usr/local/bin`
3. Create a default configuration file at `~/.dokku-migration-config`

### Basic Usage

```bash
# Edit your configuration
nano ~/.dokku-migration-config

# Run a complete migration
dokku-migration run-all

# OR run individual steps
dokku-migration export
dokku-migration import-db
dokku-migration import-apps
dokku-migration cleanup
```

### Configuration

Edit the default configuration file:

```bash
nano ~/.dokku-migration-config
```

Or specify a custom configuration file:

```bash
dokku-migration --config /path/to/config.sh run-all
```

Or override configuration via command-line:

```bash
dokku-migration \
  --source 192.168.1.10 \
  --dest 192.168.1.20 \
  --source-port 22 \
  --dest-port 22 \
  --apps "app1 app2" \
  --dbs "db1 db2" \
  --email "your-email@example.com" \
  run-all
```

## Commands

| Command | Description |
|---------|-------------|
| `export` | Export apps and databases from source server |
| `import-db` | Import databases to destination server |
| `import-apps` | Import applications to destination server |
| `cleanup` | Clean up temporary files |
| `run-all` | Run complete migration (all steps) |
| `version` | Display version information |
| `--help` | Display help message |

## What Gets Migrated

- ✅ Application Docker images
- ✅ Environment variables
- ✅ Domain configurations
- ✅ Let's Encrypt certificates
- ✅ Database content
- ✅ Persistent storage (volumes)
- ✅ Process scaling configuration

## Requirements

- SSH access to both source and destination servers
- Dokku installed on both servers
- Proper SSH key configuration

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `SOURCE_SERVER_IP` | Source server IP address | - |
| `DEST_SERVER_IP` | Destination server IP address | - |
| `SOURCE_SERVER_PORT` | Source server SSH port | 22 |
| `DEST_SERVER_PORT` | Destination server SSH port | 22 |
| `SOURCE_SERVER_KEY` | Source server SSH key file | ~/.ssh/id_rsa |
| `DEST_SERVER_KEY` | Destination server SSH key file | ~/.ssh/id_rsa |
| `APPS` | Array of applications to migrate | - |
| `DBS` | Array of databases to migrate | - |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt certificates | - |

## Examples

### Migrate specific apps

```bash
dokku-migration --apps "app1 app2" --dbs "db1 db2" run-all
```

### Migrate between remote servers

```bash
dokku-migration \
  --source remote-server-1.example.com \
  --dest remote-server-2.example.com \
  --source-key ~/.ssh/server1_key \
  --dest-key ~/.ssh/server2_key \
  run-all
```

### Export only

```bash
dokku-migration export
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Dokku](https://github.com/dokku/dokku) for making deployment awesome
- All contributors who have helped shape this tool

---

Made with ❤️ by [Pedro Alonso](https://github.com/pedropaf)