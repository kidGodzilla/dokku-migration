#!/bin/bash
set -euo pipefail

CONFIG_FILE="/root/.dokku-migration-config"
LAST_MIGRATION_FILE="/root/.dokku-migration/tmp/last_migration"

# load your APPS array (and any other vars) here
source "$CONFIG_FILE"
TEMP_DIR=$(cat "$LAST_MIGRATION_FILE")

for app in "${APPS[@]}"; do
  echo
  echo "▶️  Bootstrapping $app..."

  APP_DIR="$TEMP_DIR/apps/$app"
  IMAGE_TAR="$APP_DIR/app.docker.tar.gz"
  SCALE_FILE="$APP_DIR/scale"

  # 1) Load the image
  if [ -f "$IMAGE_TAR" ]; then
    echo "📦 Loading image for $app…"
    docker load < "$IMAGE_TAR"
  fi

  # Simplified lookup of the image ID by tag
  IMAGE_ID=$(docker images dokku/"$app":latest --format "{{.ID}}" | head -n1)
  if [ -z "$IMAGE_ID" ]; then
    echo "⚠️  No Docker image found for $app, skipping."
    continue
  fi

  TAG="dokku/$app:latest"
  echo "🏷️  Tagging $IMAGE_ID → $TAG"
  docker tag "$IMAGE_ID" "$TAG"

  # helper to apply scaling
  apply_scaling() {
    [ -f "$SCALE_FILE" ] || return
    declare -A SCALES
    while IFS= read -r line; do
      [[ $line =~ ^([a-zA-Z0-9_-]+):[[:space:]]*([0-9]+)$ ]] || continue
      SCALES["${BASH_REMATCH[1]}"]=${BASH_REMATCH[2]}
    done < "$SCALE_FILE"
    local cmd=""
    for p in "${!SCALES[@]}"; do
      cmd+="$p=${SCALES[$p]} "
    done
    if [ -n "$cmd" ]; then
      echo "📈 Scaling $app: $cmd"
      dokku ps:scale "$app" $cmd
    fi
  }

  # 3) Attempt a normal Dokku rebuild → restart
  if dokku ps:rebuild "$app"; then
    echo "✅ Rebuild succeeded, resetting to buildpacks…"
    dokku builder:set "$app" selected buildpacks >/dev/null

    apply_scaling

    if dokku ps:restart "$app"; then
      echo "✅ $app restarted successfully."
      continue
    else
      echo "⚠️  Restart failed — falling back to docker-run bootstrap."
    fi
  else
    echo "⚠️  Rebuild failed — falling back to docker-run bootstrap."
  fi

  # 4) Fallback: run the container as root with the Dokku label
  echo "🚀 Bootstrapping via docker run…"
  docker run --rm \
    --user root \
    --label com.dokku.app-name="$app" \
    "$TAG"

  # apply scaling again in case fallback created the container
  apply_scaling

  # final restart just in case
  dokku ps:restart "$app" || true
  echo "✅ $app is up (via fallback) and ready for git-push updates."
done

echo
echo "🎉 All apps processed — images bootstrapped, scaled, and ready for future git pushes."
