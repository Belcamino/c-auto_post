#!/usr/bin/env python3
import sys
import os
import json
import urllib.request
import urllib.parse
import urllib.error

def publish_post(message: str, image_url: str = None) -> dict:
    access_token = os.environ.get("IG_ACCESS_TOKEN")
    ig_user_id = os.environ.get("IG_USER_ID")
    default_image = os.environ.get("IG_DEFAULT_IMAGE_URL", "")

    if not access_token:
        raise ValueError("Missing env var: IG_ACCESS_TOKEN")
    if not ig_user_id:
        raise ValueError("Missing env var: IG_USER_ID")

    media_url = image_url or default_image
    if not media_url:
        return {
            "success": False,
            "error": "Instagram requires an image URL. Set IG_IMAGE_URL or IG_DEFAULT_IMAGE_URL env var."
        }

    base_url = "https://graph.facebook.com/v25.0"

    container_url = f"{base_url}/{ig_user_id}/media"
    container_data = urllib.parse.urlencode({
        "image_url": media_url,
        "caption": message,
        "access_token": access_token,
    }).encode("utf-8")

    req = urllib.request.Request(container_url, data=container_data, method="POST")
    try:
        with urllib.request.urlopen(req) as response:
            container_result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = json.loads(e.read().decode("utf-8"))
        return {"success": False, "error": error_body, "step": "create_container"}

    container_id = container_result.get("id")
    if not container_id:
        return {"success": False, "error": "No container ID returned", "step": "create_container"}

    publish_url = f"{base_url}/{ig_user_id}/media_publish"
    publish_data = urllib.parse.urlencode({
        "creation_id": container_id,
        "access_token": access_token,
    }).encode("utf-8")

    req2 = urllib.request.Request(publish_url, data=publish_data, method="POST")
    try:
        with urllib.request.urlopen(req2) as response:
            publish_result = json.loads(response.read().decode("utf-8"))
            return {"success": True, "post_id": publish_result.get("id")}
    except urllib.error.HTTPError as e:
        error_body = json.loads(e.read().decode("utf-8"))
        return {"success": False, "error": error_body, "step": "publish"}


if __name__ == "__main__":
    message = os.environ.get("POST_MESSAGE")
    if not message:
        print(json.dumps({"success": False, "error": "POST_MESSAGE env var not set"}))
        sys.exit(1)

    image_url = os.environ.get("POST_IMAGE_URL") or None
    result = publish_post(message, image_url)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result["success"] else 1)
