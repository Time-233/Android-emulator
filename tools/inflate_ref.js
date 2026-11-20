// 逐行镜像 Sources/Support/Inflate.swift 的 inflate 实现，用 Node 的 zlib 做 ground truth 校验。
// 目的：在没有 macOS 的情况下，验证 DEFLATE 解码算法（stored / fixed / dynamic）的正确性。
const zlib = require('zlib');

class BitSource {
  constructor(data) { this.bytes = data; this.pos = 0; this.bitBuf = 0; this.bitCnt = 0; }
  bits(n) {
    if (n === 0) return 0;
    while (this.bitCnt < n) {
      if (this.pos >= this.bytes.length) throw new Error('truncated');
      this.bitBuf |= this.bytes[this.pos] << this.bitCnt;
      this.pos += 1; this.bitCnt += 8;
    }
    const mask = ((1 << n) - 1) >>> 0;
    const value = this.bitBuf & mask;
    this.bitBuf >>>= n; this.bitCnt -= n;
    return value;
  }
  alignToByte() {
    const partial = this.bitCnt % 8;
    if (partial !== 0) { this.bitBuf >>>= partial; this.bitCnt -= partial; }
    this.pos -= Math.floor(this.bitCnt / 8);
    this.bitBuf = 0; this.bitCnt = 0;
  }
  rawBytes(n) {
    if (this.bitCnt !== 0) throw new Error('badStream');
    if (this.pos + n > this.bytes.length) throw new Error('truncated');
    const slice = this.bytes.slice(this.pos, this.pos + n);
    this.pos += n;
    return slice;
  }
}

class HuffmanTable {
  constructor(lengths) {
    this.count = new Array(16).fill(0);
    for (const length of lengths) {
      if (length < 0 || length > 15) throw new Error('badLength');
      if (length !== 0) this.count[length] += 1;
    }
    const offsets = new Array(16).fill(0);
    for (let i = 1; i < 16; i++) offsets[i] = offsets[i - 1] + this.count[i - 1];
    this.symbol = new Array(Math.max(lengths.length, 1)).fill(0);
    for (let index = 0; index < lengths.length; index++) {
      const length = lengths[index];
      if (length !== 0) { this.symbol[offsets[length]] = index; offsets[length] += 1; }
    }
  }
  decode(source) {
    let code = 0, first = 0, index = 0;
    for (let length = 1; length <= 15; length++) {
      code |= source.bits(1);
      const current = this.count[length];
      if (code - first < current) {
        const target = index + code - first;
        if (target < 0 || target >= this.symbol.length) throw new Error('badStream');
        return this.symbol[target];
      }
      index += current;
      first = (first + current) << 1;
      code <<= 1;
      if (code > 0x7fffffff) code = code >>> 0;
    }
    throw new Error('badStream');
  }
}

function fixedLiteral() {
  const lengths = new Array(288).fill(8);
  for (let i = 144; i < 256; i++) lengths[i] = 9;
  for (let i = 256; i < 280; i++) lengths[i] = 7;
  return new HuffmanTable(lengths);
}
function fixedDistance() { return new HuffmanTable(new Array(30).fill(5)); }

class RawInflate {
  constructor(data, limit) {
    this.lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
      35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
    this.lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
    this.distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
      257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
    this.distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
      7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
    this.source = new BitSource(data);
    this.output = [];
    this.limit = limit > 0 ? limit : (1 << 26);
  }
  run() {
    let isLast = 0;
    while (true) {
      isLast = this.source.bits(1);
      const type = this.source.bits(2);
      if (type === 0) this.readStored();
      else if (type === 1) this.readBlock(fixedLiteral(), fixedDistance());
      else if (type === 2) this.readDynamic();
      else throw new Error('badStream');
      if (isLast === 1) break;
    }
    return Buffer.from(this.output);
  }
  append(byte) {
    if (this.output.length > this.limit + 1024) throw new Error('tooLarge');
    this.output.push(byte);
  }
  readStored() {
    this.source.alignToByte();
    const header = this.source.rawBytes(4);
    const length = header[0] | (header[1] << 8);
    const nlength = header[2] | (header[3] << 8);
    if ((length ^ 0xFFFF) !== nlength) throw new Error('badStream');
    const payload = this.source.rawBytes(length);
    for (const byte of payload) this.append(byte);
  }
  readBlock(literal, distance) {
    while (true) {
      const symbol = literal.decode(this.source);
      if (symbol < 256) this.append(symbol);
      else if (symbol === 256) return;
      else {
        const index = symbol - 257;
        if (index < 0 || index >= this.lengthBase.length) throw new Error('badStream');
        const length = this.lengthBase[index] + this.source.bits(this.lengthExtra[index]);
        const distSymbol = distance.decode(this.source);
        if (distSymbol < 0 || distSymbol >= this.distBase.length) throw new Error('badStream');
        const dist = this.distBase[distSymbol] + this.source.bits(this.distExtra[distSymbol]);
        if (dist <= 0 || dist > this.output.length) throw new Error('badStream');
        for (let i = 0; i < length; i++) this.append(this.output[this.output.length - dist]);
      }
    }
  }
  readDynamic() {
    const hlit = this.source.bits(5) + 257;
    const hdist = this.source.bits(5) + 1;
    const hclen = this.source.bits(4) + 4;
    const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    const codeLengths = new Array(19).fill(0);
    for (let i = 0; i < hclen; i++) codeLengths[order[i]] = this.source.bits(3);
    const codeTable = new HuffmanTable(codeLengths);
    const lengths = [];
    while (lengths.length < hlit + hdist) {
      const symbol = codeTable.decode(this.source);
      if (symbol <= 15) lengths.push(symbol);
      else if (symbol === 16) {
        if (lengths.length === 0) throw new Error('badStream');
        const previous = lengths[lengths.length - 1];
        const repeatCount = this.source.bits(2) + 3;
        for (let k = 0; k < repeatCount; k++) lengths.push(previous);
      } else if (symbol === 17) {
        const repeatCount = this.source.bits(3) + 3;
        for (let k = 0; k < repeatCount; k++) lengths.push(0);
      } else if (symbol === 18) {
        const repeatCount = this.source.bits(7) + 11;
        for (let k = 0; k < repeatCount; k++) lengths.push(0);
      } else throw new Error('badStream');
      if (lengths.length > hlit + hdist + 64) throw new Error('badStream');
    }
    const literalLengths = lengths.slice(0, hlit);
    const distanceLengths = lengths.slice(hlit, hlit + hdist);
    this.readBlock(new HuffmanTable(literalLengths), new HuffmanTable(distanceLengths));
  }
}

function inflateRaw(buffer, expectedSize) {
  return new RawInflate(buffer, expectedSize).run();
}

// ------------------------------------------------------------------ 测试

function makeCorpus() {
  const cases = [];
  const text = Buffer.from('AndroidManifest.xml <manifest package="com.example.demo">权限列表'.repeat(40), 'utf8');
  cases.push({ name: 'utf8-text', data: text });

  const binary = Buffer.alloc(60000);
  for (let i = 0; i < binary.length; i++) binary[i] = (i * 37 + (i >> 3)) & 0xff;
  cases.push({ name: 'structured-binary', data: binary });

  const random = require('crypto').randomBytes(20000);
  cases.push({ name: 'random', data: random });

  const mixed = Buffer.concat([text, random, text, Buffer.alloc(3000, 0)]);
  cases.push({ name: 'mixed', data: mixed });

  cases.push({ name: 'tiny', data: Buffer.from('apk') });
  cases.push({ name: 'empty', data: Buffer.alloc(0) });
  cases.push({ name: 'zeros-1mb', data: Buffer.alloc(1024 * 1024) });
  return cases;
}

let passed = 0, failed = 0;
for (const testCase of makeCorpus()) {
  for (const level of [0, 1, 3, 6, 9]) {
    for (const strategy of [zlib.constants.Z_DEFAULT_STRATEGY, zlib.constants.Z_FIXED, zlib.constants.Z_HUFFMAN_ONLY, zlib.constants.Z_RLE]) {
      const compressed = zlib.deflateRawSync(testCase.data, { level, strategy });
      const label = `${testCase.name} L${level} S${strategy}`;
      try {
        const out = inflateRaw(compressed, testCase.data.length);
        if (!out.equals(testCase.data)) {
          console.log('MISMATCH', label, 'len', out.length, 'expected', testCase.data.length);
          failed++;
        } else { passed++; }
      } catch (error) {
        console.log('ERROR', label, error.message);
        failed++;
      }
    }
  }
}
console.log(`\n inflate 参考实现: passed=${passed} failed=${failed}`);
if (failed > 0) process.exit(1);
