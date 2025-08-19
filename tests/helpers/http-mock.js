/**
 * HTTP request mocking utilities for unit testing
 */
import sinon from 'sinon';

/**
 * Create a mock for axios HTTP client
 * @param {Object} options - Configuration options
 * @param {Object} options.responses - Map of URL patterns to mock responses
 * @param {Object} options.errors - Map of URL patterns to mock errors
 * @returns {Object} - Mock axios instance
 */
export function createAxiosMock(options = {}) {
  const { responses = {}, errors = {} } = options;

  // Create a stub for the axios methods
  const axiosMock = {
    get: sinon.stub(),
    post: sinon.stub(),
    put: sinon.stub(),
    delete: sinon.stub(),
    patch: sinon.stub(),
    request: sinon.stub(),
    interceptors: {
      request: { use: sinon.stub(), eject: sinon.stub() },
      response: { use: sinon.stub(), eject: sinon.stub() },
    },
    defaults: {
      headers: {
        common: {},
        get: {},
        post: {},
        put: {},
        patch: {},
        delete: {},
      },
    },
    // Track all requests made
    __requests: [],
    // Reset all stubs
    reset() {
      this.get.reset();
      this.post.reset();
      this.put.reset();
      this.delete.reset();
      this.patch.reset();
      this.request.reset();
      this.__requests = [];
    },
  };

  // Configure the stubs based on the provided responses and errors
  for (const [method, stub] of Object.entries({
    get: axiosMock.get,
    post: axiosMock.post,
    put: axiosMock.put,
    delete: axiosMock.delete,
    patch: axiosMock.patch,
  })) {
    stub.callsFake((url, data, config = {}) => {
      // Track the request
      axiosMock.__requests.push({ method, url, data, config });

      // Check if we have a specific error for this URL
      for (const [urlPattern, error] of Object.entries(errors)) {
        if (url.match(new RegExp(urlPattern))) {
          return Promise.reject(error);
        }
      }

      // Check if we have a specific response for this URL
      for (const [urlPattern, response] of Object.entries(responses)) {
        if (url.match(new RegExp(urlPattern))) {
          if (typeof response === 'function') {
            return Promise.resolve(response(url, data, config));
          }
          return Promise.resolve(response);
        }
      }

      // Default response
      return Promise.resolve({
        status: 200,
        statusText: 'OK',
        data: {},
        headers: {},
        config: {},
      });
    });
  }

  // Configure the request stub
  axiosMock.request.callsFake((config) => {
    const method = (config.method || 'get').toLowerCase();
    const url = config.url;
    const data = config.data;

    // Delegate to the appropriate method stub
    if (method === 'get') return axiosMock.get(url, config);
    if (method === 'post') return axiosMock.post(url, data, config);
    if (method === 'put') return axiosMock.put(url, data, config);
    if (method === 'delete') return axiosMock.delete(url, config);
    if (method === 'patch') return axiosMock.patch(url, data, config);

    // Default response
    return Promise.resolve({
      status: 200,
      statusText: 'OK',
      data: {},
      headers: {},
      config: {},
    });
  });

  return axiosMock;
}

/**
 * Create a mock for Express request and response objects
 * @returns {Object} - Object containing req and res mocks
 */
export function createExpressMocks() {
  const req = {
    body: {},
    params: {},
    query: {},
    headers: {},
    cookies: {},
    path: '/',
    method: 'GET',
    url: '/',
    ip: '127.0.0.1',
    get: sinon.stub().returns(null),
  };

  const res = {
    statusCode: 200,
    headers: {},
    body: null,

    status: sinon.stub().callsFake(function (code) {
      this.statusCode = code;
      return this;
    }),

    json: sinon.stub().callsFake(function (data) {
      this.body = data;
      return this;
    }),

    send: sinon.stub().callsFake(function (data) {
      this.body = data;
      return this;
    }),

    set: sinon.stub().callsFake(function (header, value) {
      if (typeof header === 'object') {
        Object.assign(this.headers, header);
      } else {
        this.headers[header] = value;
      }
      return this;
    }),

    end: sinon.stub().callsFake(function (data) {
      if (data) this.body = data;
      return this;
    }),

    sendStatus: sinon.stub().callsFake(function (code) {
      this.statusCode = code;
      return this;
    }),

    redirect: sinon.stub().callsFake(function (url) {
      this.redirectUrl = url;
      return this;
    }),

    cookie: sinon.stub().returns({}),
    clearCookie: sinon.stub().returns({}),

    // Event listeners
    on: sinon.stub(),
    once: sinon.stub(),
    emit: sinon.stub(),
  };

  const next = sinon.stub();

  return { req, res, next };
}

export default {
  createAxiosMock,
  createExpressMocks,
};
