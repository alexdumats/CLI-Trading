import { jest } from '@jest/globals';

const mockPoolInstance = {
  query: jest.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
  end: jest.fn().mockResolvedValue(undefined),
};

export const Pool = jest.fn().mockImplementation(() => mockPoolInstance);

export default {
  Pool,
};
