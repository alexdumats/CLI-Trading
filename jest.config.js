/** @type {import('jest').Config} */
export default {
  testEnvironment: 'node',
  transform: {},
  extensionsToTreatAsEsm: ['.jsx'],
  moduleNameMapper: {
    '^morgan$': '<rootDir>/tests/__mocks__/morgan.js',
  },
  testMatch: ['**/__tests__/**/*.js', '**/?(*.)+(spec|test).js'],
  testPathIgnorePatterns: ['/node_modules/'],
  verbose: true,
  moduleFileExtensions: ['js', 'json', 'jsx', 'node'],
  setupFiles: [],
  testEnvironmentOptions: {
    url: 'http://localhost/',
  },
  coverageDirectory: './coverage',
  collectCoverageFrom: [
    'common/**/*.js',
    'agents/**/src/**/*.js',
    '!**/node_modules/**',
    '!**/tests/**',
  ],
  coverageThreshold: {
    global: {
      statements: 70,
      branches: 60,
      functions: 70,
      lines: 70,
    },
  },
};
