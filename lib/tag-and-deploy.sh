#!/bin/bash
set -euo pipefail

CONFIG_FILE="/root/.dokku-migration-config"
LAST_MIGRATION_FILE="/root/.dokku-migration/tmp/last_migration"

source "$CONFIG_FILE"
TEMP_DIR=$(cat "$LAST_MIGRATION_FILE")

for app in "${APPS[@]}"; do
  echo "▶️  Processing $app..."

  APP_DIR="$TEMP_DIR/apps/$app"
  IMAGE_TAR="$APP_DIR/app.docker.tar.gz"
  SCALE_FILE="$APP_DIR/scale"

  # 1) Load & tag
  if [ -f "$IMAGE_TAR" ]; then
    echo "📦 Loading image for $app..."
    docker load < "$IMAGE_TAR"
  fi

  IMAGE_ID=$(docker images --format "{{.ID}}" | head -n1)
  if [ -z "$IMAGE_ID" ]; then
    echo "⚠️  No image found for $app, skipping."
    continue
  fi

  TAG="dokku/$app:latest"
  echo "🏷️  Tagging $IMAGE_ID → $TAG"
  docker tag "$IMAGE_ID" "$TAG"

  # 2) Try rebuild (uses latest tag)
  echo "🔄 Attempting dokku ps:rebuild $app..."
  if dokku ps:rebuild "$app"; then
    echo "✅ Rebuild succeeded."
    # restore buildpack mode
    dokku builder:set "$app" selected buildpacks >/dev/null
  else
    echo "⚠️  Rebuild failed — falling back to docker-run bootstrap."
    # 3) Fallback: run container as root so /cache chown works
    docker run --rm \
      --user root \
      --label com.dokku.app-name="$app" \
      "dokku/$app:latest"
  fi

  # 4) Scaling
  if [ -f "$SCALE_FILE" ]; then
    declare -A SCALES
    while read -r line; do
      [[ $line =~ ^([a-zA-Z0-9_-]+):[[:space:]]*([0-9]+)$ ]] || continue
      SCALES["${BASH_REMATCH[1]}"]=${BASH_REMATCH[2]}
    done < "$SCALE_FILE"

    SCALE_CMD=""
    for proc in "${!SCALES[@]}"; do
      SCALE_CMD+="$proc=${SCALES[$proc]} "
    done

    if [ -n "$SCALE_CMD" ]; then
      echo "📈 Scaling $app: $SCALE_CMD"
      dokku ps:scale "$app" $SCALE_CMD
    fi
  fi

  # finally, restart
  dokku ps:restart "$app"
  echo "✅ $app is up and running."
done

echo "🎉 All apps processed — images bootstrapped, scaled, and started."
