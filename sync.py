from fastapi import FastAPI
from fastapi.responses import Response
import json
import httpx
from wordfreq import random_words
import uvicorn

app = FastAPI()


@app.get("/")
def root():
    return Response(status_code=200)


@app.get("/words")
def get_words():
    result = {}
    for i in range(10):
        result[f"list_{i+1}"] = list(random_words('en', nwords=10))
    return result


@app.get("/data")
def get_data():
    response = httpx.get("https://jsonplaceholder.typicode.com/comments")
    return response.json()


@app.get("/users")
def get_users():
    with open("users.json", "r") as f:
        data = json.load(f)
    return data


if __name__ == "__main__":
    uvicorn.run("sync:app", host="0.0.0.0", port=8000, workers=1)
