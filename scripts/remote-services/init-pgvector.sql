-- 向量库初始化。应用启动时也会自建同样的表，这份 SQL 只是让首次部署一步到位，
-- 顺便说明表结构：主键是 (chunk_key, model_revision)，换嵌入模型时旧向量自然失效而不是被污染。
--
-- 640 维来自 Apple 简体中文句向量（NLEmbedding），改模型要同时改
-- PostgresVectorStore.vectorDimension 与这里的维度。
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS leetcode_rag_vectors (
  chunk_key      text        NOT NULL,
  embedding      vector(640) NOT NULL,
  model_revision integer     NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chunk_key, model_revision)
);

-- 近邻检索索引。数据量不大时顺序扫描也够快，量上来之后这个索引决定检索延迟。
CREATE INDEX IF NOT EXISTS leetcode_rag_vectors_embedding_idx
  ON leetcode_rag_vectors
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);
