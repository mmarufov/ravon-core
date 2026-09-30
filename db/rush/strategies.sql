-- strategies.sql: four checkout strategies over one hot row, in a scratch
-- schema. Illustrative, not the product: the product's checkout is
-- public.create_order in db/schema, which rush.py also drives (--target rpc).
--
-- The four are defined in db/rush/PREREGISTRATION.md, written before any run.
-- Every one of them sells one unit of item 1 per checkout.
--
--   read_then_write        client transaction; SQL lives in rush.py, not here
--   row_lock               rush.checkout_row_lock(item), one RPC
--   conditional_decrement  one statement; SQL lives in rush.py
--   reservation_rows       one statement over rush.units; SQL lives in rush.py
--
-- The single-statement SQL is kept in rush.py next to the client code that
-- sends it, so what is measured is exactly what is read.

DROP SCHEMA IF EXISTS rush CASCADE;
CREATE SCHEMA rush;

CREATE TABLE rush.items (
  id    int PRIMARY KEY,
  -- No CHECK (stock >= 0) on purpose. With the constraint, read_then_write
  -- could never write a negative number, but it never tries to: it writes
  -- `<value it read> - 1`, which is >= 0 for every read that passed its check.
  -- Its failure is a stale value, not a negative one, so a CHECK would not
  -- catch it, and leaving it out keeps the four strategies on equal terms.
  stock int NOT NULL
);

CREATE TABLE rush.orders (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id    int NOT NULL REFERENCES rush.items(id),
  qty        int NOT NULL CHECK (qty > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- One row per sellable unit, for reservation_rows. A unit is sold when its
-- order_id is set; UNIQUE makes one order claiming two units impossible.
CREATE TABLE rush.units (
  id       int PRIMARY KEY,
  item_id  int NOT NULL REFERENCES rush.items(id),
  order_id bigint UNIQUE REFERENCES rush.orders(id)
);
CREATE INDEX units_free_idx ON rush.units(item_id, id) WHERE order_id IS NULL;

INSERT INTO rush.items VALUES (1, 0);

-- row_lock: what public.create_order does for one item, and nothing else.
-- The row lock is taken and released inside one server round trip, so client
-- latency cannot lengthen it.
CREATE FUNCTION rush.checkout_row_lock(p_item int)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_stock int;
BEGIN
  SELECT stock INTO v_stock FROM rush.items WHERE id = p_item FOR UPDATE;
  IF v_stock < 1 THEN
    RETURN false;
  END IF;
  UPDATE rush.items SET stock = stock - 1 WHERE id = p_item;
  INSERT INTO rush.orders(item_id, qty) VALUES (p_item, 1);
  RETURN true;
END;
$$;

-- Reset between runs. Called by rush.py with N.
CREATE FUNCTION rush.reset(p_n int)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  TRUNCATE rush.units, rush.orders RESTART IDENTITY;
  UPDATE rush.items SET stock = p_n WHERE id = 1;
  INSERT INTO rush.units(id, item_id) SELECT g, 1 FROM generate_series(1, p_n) g;
END;
$$;
