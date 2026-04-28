import sys
import os
import requests
import json

def publish_post(message: str) -> dict:
    token = os.environ.get("FB_PAGE_TOKEN")
    page_id = os.environ.get("FB_PAGE_ID")

    if not token or not page_id:
        print("ERROR: FB_PAGE_TOKEN or FB_PAGE_ID not set", file=sys.stderr)
        sys.exit(1)

    url = f"https://graph.facebook.com/v25.0/{page_id}/feed"
    payload = {"message": message, "access_token": token}

    response = requests.post(url, data=payload)
    return response.json()

if __name__ == "__main__":
    message = os.environ.get("POST_MESSAGE")
    if not message:
        print("ERROR: POST_MESSAGE env var not set", file=sys.stderr)
        sys.exit(1)

    result = publish_post(message)

    if "id" in result:
        print(f"SUCCESS:{result['id']}")
    else:
        error = result.get("error", {})
        code = error.get("code", "unknown")
        msg = error.get("message", json.dumps(result))
        print(f"ERROR:{code}:{msg}")
        sys.exit(int(code) if str(code).isdigit() else 1)
