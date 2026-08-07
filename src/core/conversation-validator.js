'use strict';

const MAX_CONVERSATION_MESSAGES = 1000;
const MAX_MESSAGE_CONTENT_CHARS = 2 * 1024 * 1024;
const MAX_CONVERSATION_BYTES = 16 * 1024 * 1024;

function validateConversationData(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('对话数据无效');
  }
  if (!Array.isArray(value.messages) || value.messages.length > MAX_CONVERSATION_MESSAGES) {
    throw new Error(`单个对话最多保存 ${MAX_CONVERSATION_MESSAGES} 条消息`);
  }
  for (const message of value.messages) {
    if (!message || typeof message !== 'object' || typeof message.role !== 'string' || typeof message.content !== 'string') {
      throw new Error('对话消息格式无效');
    }
    if (message.content.length > MAX_MESSAGE_CONTENT_CHARS) {
      throw new Error(`单条消息不能超过 ${MAX_MESSAGE_CONTENT_CHARS} 个字符`);
    }
  }
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch (error) {
    throw new Error('对话数据无法序列化');
  }
  if (Buffer.byteLength(serialized) > MAX_CONVERSATION_BYTES) {
    throw new Error(`单个对话不能超过 ${MAX_CONVERSATION_BYTES} 字节`);
  }
  return value;
}

module.exports = {
  MAX_CONVERSATION_BYTES,
  MAX_CONVERSATION_MESSAGES,
  MAX_MESSAGE_CONTENT_CHARS,
  validateConversationData
};
