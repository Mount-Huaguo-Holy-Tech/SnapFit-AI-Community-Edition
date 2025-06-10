-- 🔄 完整的同步系统迁移脚本 (修复版本)
-- 执行前请备份数据库！

-- 0. 清理可能存在的旧函数
-- ========================

-- 删除可能存在的旧版本函数
DROP FUNCTION IF EXISTS upsert_log_patch(UUID, DATE, JSONB, TIMESTAMP WITH TIME ZONE);
DROP FUNCTION IF EXISTS merge_arrays_by_log_id(JSONB, JSONB);
DROP FUNCTION IF EXISTS remove_log_entry(UUID, DATE, TEXT, TEXT);
DROP FUNCTION IF EXISTS atomic_usage_check_and_increment(UUID, TEXT, INTEGER);
DROP FUNCTION IF EXISTS decrement_usage_count(UUID, TEXT);

-- 1. 添加缺少的约束和索引
-- ================================

-- daily_logs 表优化
DO $$
BEGIN
    -- 添加唯一约束（如果不存在）
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'daily_logs_user_date_unique'
    ) THEN
        ALTER TABLE daily_logs ADD CONSTRAINT daily_logs_user_date_unique UNIQUE (user_id, date);
    END IF;
END $$;

-- 创建索引（如果不存在）
CREATE INDEX IF NOT EXISTS idx_daily_logs_user_id ON daily_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_daily_logs_date ON daily_logs(date);
CREATE INDEX IF NOT EXISTS idx_daily_logs_user_date ON daily_logs(user_id, date);
CREATE INDEX IF NOT EXISTS idx_daily_logs_last_modified ON daily_logs(last_modified);

-- ai_memories 表优化
DO $$
BEGIN
    -- 添加唯一约束（如果不存在）
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ai_memories_user_expert_unique'
    ) THEN
        ALTER TABLE ai_memories ADD CONSTRAINT ai_memories_user_expert_unique UNIQUE (user_id, expert_id);
    END IF;
END $$;

-- 创建索引（如果不存在）
CREATE INDEX IF NOT EXISTS idx_ai_memories_user_id ON ai_memories(user_id);
CREATE INDEX IF NOT EXISTS idx_ai_memories_expert_id ON ai_memories(expert_id);
CREATE INDEX IF NOT EXISTS idx_ai_memories_last_updated ON ai_memories(last_updated);

-- 2. 创建智能数组合并函数
-- ========================

CREATE OR REPLACE FUNCTION merge_arrays_by_log_id(
  existing_array JSONB,
  new_array JSONB
)
RETURNS JSONB AS $$
DECLARE
  result JSONB := '[]'::jsonb;
  existing_item JSONB;
  new_item JSONB;
  existing_ids TEXT[];
  new_ids TEXT[];
  all_ids TEXT[];
  item_id TEXT;
BEGIN
  -- 如果任一数组为空，返回另一个
  IF existing_array IS NULL OR jsonb_array_length(existing_array) = 0 THEN
    RETURN COALESCE(new_array, '[]'::jsonb);
  END IF;

  IF new_array IS NULL OR jsonb_array_length(new_array) = 0 THEN
    RETURN existing_array;
  END IF;

  -- 收集所有 log_id
  SELECT array_agg(DISTINCT item->>'log_id') INTO existing_ids
  FROM jsonb_array_elements(existing_array) AS item
  WHERE item->>'log_id' IS NOT NULL;

  SELECT array_agg(DISTINCT item->>'log_id') INTO new_ids
  FROM jsonb_array_elements(new_array) AS item
  WHERE item->>'log_id' IS NOT NULL;

  -- 合并所有唯一ID
  SELECT array_agg(DISTINCT unnest) INTO all_ids
  FROM unnest(COALESCE(existing_ids, ARRAY[]::TEXT[]) || COALESCE(new_ids, ARRAY[]::TEXT[])) AS unnest;

  -- 对每个ID，选择最新的版本
  FOR item_id IN SELECT unnest(COALESCE(all_ids, ARRAY[]::TEXT[]))
  LOOP
    -- 从新数组中查找
    SELECT item INTO new_item
    FROM jsonb_array_elements(new_array) AS item
    WHERE item->>'log_id' = item_id
    LIMIT 1;

    IF new_item IS NOT NULL THEN
      -- 新数组中有此项，使用新版本
      result := result || jsonb_build_array(new_item);
    ELSE
      -- 新数组中没有，从现有数组中获取
      SELECT item INTO existing_item
      FROM jsonb_array_elements(existing_array) AS item
      WHERE item->>'log_id' = item_id
      LIMIT 1;

      IF existing_item IS NOT NULL THEN
        result := result || jsonb_build_array(existing_item);
      END IF;
    END IF;
  END LOOP;

  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- 3. 创建安全的日志补丁更新函数
-- ============================

CREATE OR REPLACE FUNCTION upsert_log_patch(
  p_user_id UUID,
  p_date DATE,
  p_log_data_patch JSONB,
  p_last_modified TIMESTAMP WITH TIME ZONE,
  p_based_on_modified TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, conflict_resolved BOOLEAN, final_modified TIMESTAMP WITH TIME ZONE) AS $$
DECLARE
  current_modified TIMESTAMP WITH TIME ZONE;
  current_data JSONB;
  merged_data JSONB;
  conflict_detected BOOLEAN := FALSE;
BEGIN
  -- 🔒 获取当前记录（带行锁）
  SELECT last_modified, log_data INTO current_modified, current_data
  FROM daily_logs
  WHERE user_id = p_user_id AND date = p_date
  FOR UPDATE;

  -- 🔍 检测冲突：使用基于的版本时间戳进行检查
  -- 如果提供了 p_based_on_modified，则使用它进行冲突检测
  -- 否则回退到旧的逻辑（向后兼容）
  IF current_modified IS NOT NULL THEN
    IF p_based_on_modified IS NOT NULL THEN
      -- 新的乐观锁逻辑：检查服务器版本是否比客户端基于的版本新
      IF current_modified > p_based_on_modified THEN
        conflict_detected := TRUE;
      END IF;
    ELSE
      -- 旧的逻辑（向后兼容）
      IF current_modified > p_last_modified THEN
        conflict_detected := TRUE;
      END IF;
    END IF;
  END IF;

  IF conflict_detected THEN

    -- 🧠 智能合并策略
    merged_data := COALESCE(current_data, '{}'::jsonb);

    -- 对于数组字段，使用智能合并
    IF p_log_data_patch ? 'foodEntries' THEN
      merged_data := jsonb_set(
        merged_data,
        '{foodEntries}',
        merge_arrays_by_log_id(
          current_data->'foodEntries',
          p_log_data_patch->'foodEntries'
        )
      );
    END IF;

    IF p_log_data_patch ? 'exerciseEntries' THEN
      merged_data := jsonb_set(
        merged_data,
        '{exerciseEntries}',
        merge_arrays_by_log_id(
          current_data->'exerciseEntries',
          p_log_data_patch->'exerciseEntries'
        )
      );
    END IF;

    -- 对于非数组字段，使用补丁覆盖
    merged_data := merged_data || (p_log_data_patch - 'foodEntries' - 'exerciseEntries');

  ELSE
    -- 无冲突，直接合并
    merged_data := COALESCE(current_data, '{}'::jsonb);

    -- 安全合并数组字段
    IF p_log_data_patch ? 'foodEntries' THEN
      merged_data := jsonb_set(
        merged_data,
        '{foodEntries}',
        merge_arrays_by_log_id(
          current_data->'foodEntries',
          p_log_data_patch->'foodEntries'
        )
      );
    END IF;

    IF p_log_data_patch ? 'exerciseEntries' THEN
      merged_data := jsonb_set(
        merged_data,
        '{exerciseEntries}',
        merge_arrays_by_log_id(
          current_data->'exerciseEntries',
          p_log_data_patch->'exerciseEntries'
        )
      );
    END IF;

    -- 合并其他字段
    merged_data := merged_data || (p_log_data_patch - 'foodEntries' - 'exerciseEntries');
  END IF;

  -- 🔒 原子性更新或插入
  INSERT INTO daily_logs (user_id, date, log_data, last_modified)
  VALUES (
    p_user_id,
    p_date,
    merged_data,
    GREATEST(COALESCE(current_modified, p_last_modified), p_last_modified)
  )
  ON CONFLICT (user_id, date)
  DO UPDATE SET
    log_data = EXCLUDED.log_data,
    last_modified = EXCLUDED.last_modified;

  -- 返回最终的修改时间
  SELECT last_modified INTO current_modified
  FROM daily_logs
  WHERE user_id = p_user_id AND date = p_date;

  RETURN QUERY SELECT TRUE, conflict_detected, current_modified;
END;
$$ LANGUAGE plpgsql;

-- 4. 创建安全删除条目函数
-- ========================

CREATE OR REPLACE FUNCTION remove_log_entry(
  p_user_id UUID,
  p_date DATE,
  p_entry_type TEXT, -- 'food' 或 'exercise'
  p_log_id TEXT
)
RETURNS TABLE(success BOOLEAN, entries_remaining INTEGER) AS $$
DECLARE
  current_data JSONB;
  updated_array JSONB;
  field_name TEXT;
BEGIN
  -- 确定字段名
  IF p_entry_type = 'food' THEN
    field_name := 'foodEntries';
  ELSIF p_entry_type = 'exercise' THEN
    field_name := 'exerciseEntries';
  ELSE
    RETURN QUERY SELECT FALSE, 0;
    RETURN;
  END IF;

  -- 🔒 获取当前数据（带行锁）
  SELECT log_data INTO current_data
  FROM daily_logs
  WHERE user_id = p_user_id AND date = p_date
  FOR UPDATE;

  IF current_data IS NULL THEN
    RETURN QUERY SELECT FALSE, 0;
    RETURN;
  END IF;

  -- 过滤掉指定的条目
  SELECT jsonb_agg(item) INTO updated_array
  FROM jsonb_array_elements(current_data->field_name) AS item
  WHERE item->>'log_id' != p_log_id;

  -- 更新数据
  UPDATE daily_logs
  SET
    log_data = jsonb_set(log_data, ('{' || field_name || '}')::text[], COALESCE(updated_array, '[]'::jsonb)),
    last_modified = NOW()
  WHERE user_id = p_user_id AND date = p_date;

  -- 返回剩余条目数
  RETURN QUERY SELECT TRUE, COALESCE(jsonb_array_length(updated_array), 0);
END;
$$ LANGUAGE plpgsql;

-- 5. 创建使用量控制函数
-- ====================

CREATE OR REPLACE FUNCTION atomic_usage_check_and_increment(
  p_user_id UUID,
  p_usage_type TEXT,
  p_daily_limit INTEGER
)
RETURNS TABLE(allowed BOOLEAN, new_count INTEGER) AS $$
DECLARE
  current_count INTEGER := 0;
  new_count INTEGER := 0;
BEGIN
  -- 🔒 获取当前使用量（带行锁防止并发）
  SELECT COALESCE(
    CASE
      WHEN (log_data->>p_usage_type) IS NULL THEN 0
      WHEN (log_data->>p_usage_type) = 'null' THEN 0
      ELSE (log_data->>p_usage_type)::int
    END,
    0
  )
  INTO current_count
  FROM daily_logs
  WHERE user_id = p_user_id AND date = CURRENT_DATE
  FOR UPDATE;

  -- 确保 current_count 不是 NULL
  current_count := COALESCE(current_count, 0);

  -- 🚫 严格检查限额 - 绝对不允许超过
  IF current_count >= p_daily_limit THEN
    RETURN QUERY SELECT FALSE, current_count;
    RETURN;
  END IF;

  -- ✅ 未超过限额，原子性递增
  new_count := current_count + 1;

  -- 🔒 原子性更新或插入
  INSERT INTO daily_logs (user_id, date, log_data)
  VALUES (
    p_user_id,
    CURRENT_DATE,
    jsonb_build_object(p_usage_type, new_count)
  )
  ON CONFLICT (user_id, date)
  DO UPDATE SET
    log_data = COALESCE(daily_logs.log_data, '{}'::jsonb) || jsonb_build_object(
      p_usage_type,
      new_count
    ),
    last_modified = NOW();

  -- ✅ 返回成功结果
  RETURN QUERY SELECT TRUE, new_count;
END;
$$ LANGUAGE plpgsql;

-- 6. 创建回滚函数
-- ===============

CREATE OR REPLACE FUNCTION decrement_usage_count(
  p_user_id UUID,
  p_usage_type TEXT
)
RETURNS INTEGER AS $$
DECLARE
  current_count INTEGER := 0;
  new_count INTEGER := 0;
BEGIN
  -- 🔒 获取当前使用量（带行锁）
  SELECT COALESCE((log_data->>p_usage_type)::int, 0)
  INTO current_count
  FROM daily_logs
  WHERE user_id = p_user_id AND date = CURRENT_DATE
  FOR UPDATE;

  -- 确保不会变成负数
  new_count := GREATEST(current_count - 1, 0);

  -- 更新记录
  UPDATE daily_logs
  SET
    log_data = COALESCE(log_data, '{}'::jsonb) || jsonb_build_object(p_usage_type, new_count),
    last_modified = NOW()
  WHERE user_id = p_user_id AND date = CURRENT_DATE;

  RETURN new_count;
END;
$$ LANGUAGE plpgsql;

-- 7. 清理现有数据中的 null 值
-- ===========================

UPDATE daily_logs
SET log_data = jsonb_set(
  COALESCE(log_data, '{}'::jsonb),
  '{conversation_count}',
  '0'::jsonb
)
WHERE log_data->>'conversation_count' IS NULL
   OR log_data->>'conversation_count' = 'null';

UPDATE daily_logs
SET log_data = jsonb_set(
  COALESCE(log_data, '{}'::jsonb),
  '{api_call_count}',
  '0'::jsonb
)
WHERE log_data->>'api_call_count' IS NULL
   OR log_data->>'api_call_count' = 'null';

UPDATE daily_logs
SET log_data = jsonb_set(
  COALESCE(log_data, '{}'::jsonb),
  '{upload_count}',
  '0'::jsonb
)
WHERE log_data->>'upload_count' IS NULL
   OR log_data->>'upload_count' = 'null';

-- 8. 验证迁移结果
-- ===============

DO $$
DECLARE
  test_result RECORD;
  test_user_id UUID;
  merge_result JSONB;
  existing_user_id UUID;
BEGIN
  -- 获取一个现有的用户ID进行测试，如果没有则跳过使用量测试
  SELECT id INTO existing_user_id FROM users LIMIT 1;

  IF existing_user_id IS NOT NULL THEN
    -- 测试原子性使用量控制函数
    SELECT * INTO test_result FROM atomic_usage_check_and_increment(
      existing_user_id,
      'test_migration_count',
      10
    );

    IF test_result.allowed = TRUE AND test_result.new_count >= 1 THEN
      RAISE NOTICE '✅ atomic_usage_check_and_increment function working correctly';

      -- 清理测试数据
      UPDATE daily_logs
      SET log_data = log_data - 'test_migration_count'
      WHERE user_id = existing_user_id AND date = CURRENT_DATE;
    ELSE
      RAISE EXCEPTION '❌ atomic_usage_check_and_increment function failed';
    END IF;
  ELSE
    RAISE NOTICE '⚠️ No users found, skipping usage function test (this is OK for new installations)';
  END IF;

  -- 测试数组合并函数（不需要数据库数据）
  SELECT merge_arrays_by_log_id(
    '[{"log_id": "1", "name": "test1"}]'::jsonb,
    '[{"log_id": "2", "name": "test2"}]'::jsonb
  ) INTO merge_result;

  IF jsonb_array_length(merge_result) = 2 THEN
    RAISE NOTICE '✅ merge_arrays_by_log_id function working correctly';
  ELSE
    RAISE EXCEPTION '❌ merge_arrays_by_log_id function failed';
  END IF;

  -- 测试 upsert_log_patch 函数（仅语法检查，不实际插入数据）
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'upsert_log_patch'
    AND pronargs = 4
  ) THEN
    RAISE NOTICE '✅ upsert_log_patch function created successfully';
  ELSE
    RAISE EXCEPTION '❌ upsert_log_patch function not found';
  END IF;

  -- 测试 remove_log_entry 函数
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'remove_log_entry'
    AND pronargs = 4
  ) THEN
    RAISE NOTICE '✅ remove_log_entry function created successfully';
  ELSE
    RAISE EXCEPTION '❌ remove_log_entry function not found';
  END IF;

  RAISE NOTICE '🎉 All migration tests passed successfully!';
END $$;

-- 9. 创建函数权限
-- ===============

-- 确保服务角色有执行权限
GRANT EXECUTE ON FUNCTION merge_arrays_by_log_id(JSONB, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION upsert_log_patch(UUID, DATE, JSONB, TIMESTAMP WITH TIME ZONE) TO service_role;
GRANT EXECUTE ON FUNCTION remove_log_entry(UUID, DATE, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION atomic_usage_check_and_increment(UUID, TEXT, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION decrement_usage_count(UUID, TEXT) TO service_role;

-- 10. 添加函数注释
-- ================

COMMENT ON FUNCTION merge_arrays_by_log_id(JSONB, JSONB) IS '智能合并数组，基于log_id去重';
COMMENT ON FUNCTION upsert_log_patch(UUID, DATE, JSONB, TIMESTAMP WITH TIME ZONE) IS '安全的日志补丁更新，支持冲突检测';
COMMENT ON FUNCTION remove_log_entry(UUID, DATE, TEXT, TEXT) IS '安全删除日志条目';
COMMENT ON FUNCTION atomic_usage_check_and_increment(UUID, TEXT, INTEGER) IS '原子性使用量检查和递增';
COMMENT ON FUNCTION decrement_usage_count(UUID, TEXT) IS '使用量回滚函数';

-- 🎉 迁移完成！
-- =============

SELECT
  '🎉 Migration completed successfully! Functions created: ' || count(*) ||
  ' | Check the logs above for test results.' as result
FROM pg_proc
WHERE proname IN (
  'merge_arrays_by_log_id',
  'upsert_log_patch',
  'remove_log_entry',
  'atomic_usage_check_and_increment',
  'decrement_usage_count'
);
