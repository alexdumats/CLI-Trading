/**
 * Redis mock for unit testing
 */
export class RedisMock {
  constructor() {
    this.data = new Map();
    this.streams = new Map();
    this.pubsub = new Map();
    this.hashes = new Map();
  }

  // Basic operations
  async set(key, value, ...args) {
    if (args.includes('NX') && this.data.has(key)) {
      return null;
    }
    this.data.set(key, value);
    return 'OK';
  }

  async get(key) {
    return this.data.get(key) || null;
  }

  async del(key) {
    this.data.delete(key);
    return 1;
  }

  async exists(key) {
    if (this.data.has(key)) return 1;
    if (this.hashes.has(key) && this.hashes.get(key).size > 0) return 1;
    return 0;
  }

  // Hash operations
  async hset(key, ...args) {
    if (!this.hashes.has(key)) {
      this.hashes.set(key, new Map());
    }
    const hash = this.hashes.get(key);

    if (args.length === 1 && typeof args[0] === 'object' && args[0] !== null) {
      let added = 0;
      Object.entries(args[0]).forEach(([field, value]) => {
        if (!hash.has(field)) added += 1;
        hash.set(field, value);
      });
      return added;
    } else {
      // Handle field, value pairs
      let added = 0;
      for (let i = 0; i < args.length; i += 2) {
        if (i + 1 < args.length) {
          const field = args[i];
          const value = args[i + 1];
          if (!hash.has(field)) added += 1;
          hash.set(field, value);
        }
      }
      return added;
    }
  }

  async hget(key, field) {
    const hash = this.hashes.get(key);
    if (!hash) return null;
    return hash.get(field) || null;
  }

  async hgetall(key) {
    const hash = this.hashes.get(key);
    if (!hash || hash.size === 0) return {};
    return Object.fromEntries(hash.entries());
  }

  async hdel(key, ...fields) {
    const hash = this.hashes.get(key);
    if (!hash) return 0;
    let count = 0;
    for (const field of fields) {
      if (hash.has(field)) {
        hash.delete(field);
        count++;
      }
    }
    return count;
  }

  async hincrby(key, field, increment) {
    if (!this.hashes.has(key)) {
      this.hashes.set(key, new Map());
    }
    const hash = this.hashes.get(key);
    const current = parseInt(hash.get(field) || '0', 10);
    const newValue = current + parseInt(increment, 10);
    hash.set(field, newValue.toString());
    return newValue;
  }

  async hincrbyfloat(key, field, increment) {
    if (!this.hashes.has(key)) {
      this.hashes.set(key, new Map());
    }
    const hash = this.hashes.get(key);
    const current = parseFloat(hash.get(field) || '0');
    const newValue = current + parseFloat(increment);
    hash.set(field, newValue.toString());
    return newValue;
  }

  // Stream operations
  async xadd(stream, id, ...args) {
    if (!this.streams.has(stream)) {
      this.streams.set(stream, []);
    }
    const streamData = this.streams.get(stream);
    const actualId = id === '*' ? Date.now().toString() : id;
    const entry = [actualId, [...args]];
    streamData.push(entry);
    return actualId;
  }

  async xread(...args) {
    const streamIndex = args.indexOf('STREAMS');
    if (streamIndex === -1 || streamIndex + 1 >= args.length) return null;

    const streamName = args[streamIndex + 1];
    const streamData = this.streams.get(streamName) || [];
    if (streamData.length === 0) return null;

    return [[streamName, streamData]];
  }

  async xgroup(cmd, stream, group, id, ...args) {
    if (cmd.toUpperCase() !== 'CREATE') {
      throw new Error('Only CREATE command is mocked');
    }

    if (!this.streams.has(stream)) {
      if (args.includes('MKSTREAM')) {
        this.streams.set(stream, []);
      } else {
        throw new Error('Stream does not exist');
      }
    }

    return 'OK';
  }

  async xreadgroup(...args) {
    const streamIndex = args.indexOf('STREAMS');
    if (streamIndex === -1 || streamIndex + 1 >= args.length) return null;

    const streamName = args[streamIndex + 1];
    const streamData = this.streams.get(streamName) || [];
    if (streamData.length === 0) return null;

    return [[streamName, streamData]];
  }

  async xack() {
    return 1;
  }

  async xpending() {
    // Return [count, smallestId, greatestId, [ [consumer, count], ... ] ]
    return [0, null, null, []];
  }

  async xrevrange(stream) {
    const streamData = this.streams.get(stream) || [];
    return [...streamData].reverse();
  }

  // PubSub operations
  async publish(channel, message) {
    if (!this.pubsub.has(channel)) {
      this.pubsub.set(channel, []);
    }
    this.pubsub.get(channel).push(message);
    return 1;
  }

  async subscribe() {
    return 'OK';
  }

  // Utility methods
  async ping() {
    return 'PONG';
  }

  async quit() {
    return 'OK';
  }

  // Scan operation
  async scan(cursor, ...args) {
    const keys = Array.from(this.data.keys());
    return ['0', keys];
  }
}

export default function createRedisMock() {
  return new RedisMock();
}
