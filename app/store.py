import os

import redis.asyncio as aioredis


def make_redis():
    """Redis connection from REDIS_URL. 'fakeredis://' = in-memory (tests / solo dev only)."""
    url = os.environ.get("REDIS_URL", "redis://localhost:6379")
    if url.startswith("fakeredis"):
        import fakeredis.aioredis
        return fakeredis.aioredis.FakeRedis(decode_responses=True)
    return aioredis.from_url(url, decode_responses=True)
