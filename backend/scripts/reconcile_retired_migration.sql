-- Only needed for databases that ran the unpublished version of migration 13.
-- With the server stopped and a backup taken, run this with psql before upgrading.
-- Migration 14 drops both tables created by 13; the final schema is unchanged.
update _sqlx_migrations
set checksum = decode('1998df2724eabb75524d9716b132bf971016f300cc8bda137903e10665c7d809c899d91013a4b66716da2f45858f1c88', 'hex')
where version = 13 and success
  and checksum = decode('c129160a0835a70f2180979a372f8f5b978236bc52d154466f706a8dc6f76932ec7212a3e55bad4ec71d989772ed7f95', 'hex');
