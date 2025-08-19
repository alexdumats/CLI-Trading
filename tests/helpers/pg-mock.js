/**
 * PostgreSQL mock for unit testing
 */
export class PgPoolMock {
  constructor(options = {}) {
    this.tables = new Map();
    this.queryLog = [];
    this.queryResults = options.queryResults || new Map();
    this.queryErrors = options.queryErrors || new Map();
    this.defaultResult = { rows: [], rowCount: 0 };
  }

  /**
   * Set up mock data for a table
   * @param {string} tableName - Name of the table
   * @param {Array} rows - Array of row objects
   */
  setTableData(tableName, rows) {
    this.tables.set(tableName, [...rows]);
  }

  /**
   * Set up a mock result for a specific query
   * @param {string|RegExp} query - SQL query string or regex pattern
   * @param {Object} result - Result object with rows and rowCount
   */
  setQueryResult(query, result) {
    this.queryResults.set(query.toString(), result);
  }

  /**
   * Set up a mock error for a specific query
   * @param {string|RegExp} query - SQL query string or regex pattern
   * @param {Error} error - Error to throw
   */
  setQueryError(query, error) {
    this.queryErrors.set(query.toString(), error);
  }

  /**
   * Execute a mock query
   * @param {string} text - SQL query
   * @param {Array} params - Query parameters
   * @returns {Promise<Object>} - Query result
   */
  async query(text, params = []) {
    const queryInfo = { text, params, timestamp: new Date() };
    this.queryLog.push(queryInfo);

    // Check for exact query match
    if (this.queryErrors.has(text)) {
      throw this.queryErrors.get(text);
    }

    if (this.queryResults.has(text)) {
      return this.queryResults.get(text);
    }

    // Check for regex matches
    for (const [queryPattern, error] of this.queryErrors.entries()) {
      if (queryPattern.startsWith('/') && new RegExp(queryPattern.slice(1, -1)).test(text)) {
        throw error;
      }
    }

    for (const [queryPattern, result] of this.queryResults.entries()) {
      if (queryPattern.startsWith('/') && new RegExp(queryPattern.slice(1, -1)).test(text)) {
        return result;
      }
    }

    // Default behavior based on query type
    if (text.toLowerCase().startsWith('select')) {
      return this._handleSelect(text, params);
    } else if (text.toLowerCase().startsWith('insert')) {
      return this._handleInsert(text, params);
    } else if (text.toLowerCase().startsWith('update')) {
      return this._handleUpdate(text, params);
    } else if (text.toLowerCase().startsWith('delete')) {
      return this._handleDelete(text, params);
    }

    return this.defaultResult;
  }

  /**
   * Handle SELECT queries (very simplified)
   */
  _handleSelect(text, params) {
    // This is a very simplified implementation
    // In a real mock, you would parse the SQL and apply filters
    const tableMatch = text.match(/from\s+([a-zA-Z_]+)/i);
    if (tableMatch && tableMatch[1]) {
      const tableName = tableMatch[1];
      const rows = this.tables.get(tableName) || [];
      return { rows, rowCount: rows.length };
    }
    return this.defaultResult;
  }

  /**
   * Handle INSERT queries (very simplified)
   */
  _handleInsert(text, params) {
    // This is a very simplified implementation
    const tableMatch = text.match(/into\s+([a-zA-Z_]+)/i);
    if (tableMatch && tableMatch[1]) {
      const tableName = tableMatch[1];
      if (!this.tables.has(tableName)) {
        this.tables.set(tableName, []);
      }
      // In a real implementation, you would parse the values and add them
      return { rowCount: 1 };
    }
    return this.defaultResult;
  }

  /**
   * Handle UPDATE queries (very simplified)
   */
  _handleUpdate(text, params) {
    // This is a very simplified implementation
    const tableMatch = text.match(/update\s+([a-zA-Z_]+)/i);
    if (tableMatch && tableMatch[1]) {
      return { rowCount: 1 };
    }
    return this.defaultResult;
  }

  /**
   * Handle DELETE queries (very simplified)
   */
  _handleDelete(text, params) {
    // This is a very simplified implementation
    const tableMatch = text.match(/from\s+([a-zA-Z_]+)/i);
    if (tableMatch && tableMatch[1]) {
      return { rowCount: 1 };
    }
    return this.defaultResult;
  }

  /**
   * Get the query log
   * @returns {Array} - Array of executed queries
   */
  getQueryLog() {
    return [...this.queryLog];
  }

  /**
   * Clear the query log
   */
  clearQueryLog() {
    this.queryLog = [];
  }

  /**
   * Mock the connect method
   */
  async connect() {
    return {
      query: this.query.bind(this),
      release: () => {},
    };
  }

  /**
   * Mock the end method
   */
  async end() {
    return;
  }
}

export default function createPgPoolMock(options = {}) {
  return new PgPoolMock(options);
}
