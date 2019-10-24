
for /R %%s in (*.dot) do (
dot -Tsvg %%s   -o..\dot_dest\%%~ns.svg
rem dot -Tpng -Gdpi=300  %%s   -o..\dest\%%~ns.png
)



rem ..\dest\test.svg