import json, os  # python3 tool/gen_grammar_table.py regenerates test/grammar_table.json
R=[]
def v(text, value, field=None, **kw): R.append(dict(text=text, field=field, expect=dict(value=value, **kw)))
def p(text, value, field, **kw): R.append(dict(text=text, field=field, expect=dict(plain=value, **kw)))
def e(text, code, s, en, field=None, **kw): R.append(dict(text=text, field=field, expect=dict(error=code, start=s, end=en, **kw)))
A='event.amount'; S='stream.seed'; RT='loan.ratePct'; C='event.count'
# --- sample table (variables-plan-review.md)
v('$some_var_name','5',A); v('$some_var_name * $another_var_name','15',A); v('$some_var_name * 3','15',A)
v('$rent * 12 / $weeks','276.92',A); v('($rent + 50) * 2','2500',A); v('-$rent + 2000','800',S)
v('2 * -3','-6',S); e('2 * -3','out_of_range',0,6,A,message='Use Money out instead of a negative amount')
v('10 / 3 * 3','10',A); v('0.1 + 0.2','0.3',A); v('2.675 * 1','2.68',A); p('-2.345','-2.345',S)
v('$Rent / 4','300',A,canonical='$rent / 4'); v('5 × 3 − 1','14',A,canonical='5 * 3 - 1'); v('$100 + $rent','1300',A)
v('$rate + 0.25','5.75',RT); e('$rate * 20','out_of_range',0,10,RT); v('$rate / 3','1.8333',RT)
v('$weeks / 4','13',C); e('$weeks / 5','not_whole',0,10,C,message='Must be a whole number; this works out to 10.4')
e('$rent / $zero','division_by_zero',6,7,A,message='Division by zero: $zero is 0')
e('$rnt * 2','unknown_variable',0,4,A,hint='Did you mean $rent?')
e('5 +','expected_operand',3,3,A); e('(5 + 3','unclosed_paren',0,1,A); e('5 + 3)','unmatched_paren',5,6,A)
e('5 5','missing_operator',2,3)            # parser level: the sample row
p('5 5','55',A)                            # D14: parseMoneyInput strips spaces today
e('1,250 + 5','reserved_syntax',1,2,A,message="Commas can't be used inside a formula; write 1250 or 1_250")
p('1,250','1250',A)
e('5%','reserved_syntax',1,2,RT,message="Percent signs aren't supported yet. Write 5 / 100 for 5%.")
e('round($rent / 7)','reserved_syntax',0,5,A,message="Functions like round() aren't supported yet")
# --- precedence / associativity
for t,val in [('10-2-3','5'),('12/2/3','2'),('-3*2','-6'),('2*-3','-6'),('--5','5'),('+5','5'),('-(2+3)','-5'),
  ('2+3*4','14'),('(2+3)*4','20'),('2*3+4','10'),('8/4*2','4'),('8/(4*2)','1'),('1-2+3','2'),('-2*-2','4'),
  ('-+-5','5'),('2--3','5'),('2+-3','-1'),('2*+3','6'),('((((1))))','1'),('-(-(1))','1'),('10/4','5/2'),
  ('1/3','1/3'),('1/3+1/3+1/3','1'),('2*(3+4)*5','70'),('100-50/2','75'),('7/7/7','1/7'),('-2-2','-4'),
  ('2*3/4','3/2'),('2/3*3','2'),('6-(2-1)','5'),('6-2-1','3'),('-(1)*-(1)','1'),('1+2+3+4+5','15')]:
    v(t,val)
# --- whitespace
v('\t5\t+\t3\t','8'); v('5\u00a0+\u00a03','8'); v('5\u202f*\u202f2','10'); v('  5  ','5'); v(' 5 + 3 ','8'); v('5+3','8')
e('5\n+3','unexpected_character',1,2)
# --- aliases
for t,val in [('5 − 2','3'),('5 – 2','3'),('5 — 2','3'),('3 × 4','12'),('3 · 4','12'),('8 ÷ 2','4'),('−5','-5'),('6÷3×2','4'),('—(2)','-2')]: v(t,val)
v('5 – 2 × 3','-1',A,canonical=None) if False else None
e('5 x 3','missing_operator',2,3,message='Use * to multiply'); e('5 X 3','missing_operator',2,3)
# --- digit separators
for t,val in [('1_250','1250'),('1_250.5','1250.5'),('1_2_3','123'),('1.2_5','1.25'),('0_0','0')]: v(t,val)
for t,s,en in [('1__250',0,6),('1_',0,2),('1_.5',0,4),('1._5',0,4),('1_ + 2',0,2)]: e(t,'bad_number',s,en)
e('_1','reserved_syntax',0,2)
# --- decimals
for t,val in [('.5','0.5'),('0.5','0.5'),('1.1234567890','1.123456789'),('123456789012345','123456789012345'),('0001','1'),('00.50','0.5'),('.5+.5','1')]: v(t,val)
e('5.','bad_number',0,2,message='Add digits after the decimal point'); e('5.5.5','bad_number',0,5); e('5. + 1','bad_number',0,2)
e('1.12345678901','number_too_long',0,13); e('1234567890123456','number_too_long',0,16); e('1234567890123456.5','number_too_long',0,18)
e('.','unexpected_character',0,1); e('5 + .','unexpected_character',4,5)
e('1e3','bad_number',0,3); e('2E10','bad_number',0,4); e('1e+3','bad_number',0,2)
# --- every error code with spans
e('','empty',0,0); e('   ','empty',0,0); e('\t','empty',0,0)
for t,s,en in [('5 & 3',2,3),('@',0,1),('5 + #',4,5),('5 = 3',2,3),('5\u00a0+\u00a0"',4,5),('[1]',0,1),('5 +\r3',3,4)]: e(t,'unexpected_character',s,en)
for t,s,en in [('* 5',0,1),('/5',0,1),('5 + * 3',4,5),('5 * / 3',4,5),('(* 2)',1,2)]: e(t,'unexpected_token',s,en)
for t,s,en in [('5 *',3,3),('()',1,2),('(5 + )',5,6),('-',1,1),('5 + (',5,5),('$',0,1),('$ + 1',0,1),(')',0,1),('5 - -',5,5),('(',1,1)]: e(t,'expected_operand',s,en)
for t,s,en in [('2(3)',1,4),('2 $rent',2,7),('(1)(2)',3,6),('$rent $rent',6,11),('5 5 5',2,3),('1 (2 + 3)',2,9),('$rent2',None,None)]:
    if s is not None: e(t,'missing_operator',s,en)
e('2(3)','missing_operator',1,4,message='Add an operator between 2 and (')
for t,s,en in [('((1)',0,1),('(1 + (2)',0,1),('5 * (3 + (4 - 1)',4,5),('(((',2,3) if False else ('((1',1,2)]: e(t,'unclosed_paren',s,en)
for t,s,en in [('1)',1,2),('(1))',3,4),('1 + 2) * 3',5,6)]: e(t,'unmatched_paren',s,en)
e('$nope','unknown_variable',0,5,message='There is no variable $nope'); e('$Rnt','unknown_variable',0,4,hint='Did you mean $rent?')
e('$rents','unknown_variable',0,6,hint='Did you mean $rent?'); e('$xyz + $rent','unknown_variable',0,4)
e('$rent + $nope','unknown_variable',8,13); e('$' + 'a'*41,'unknown_variable',0,42)
for t,s,en,msg in [('5^2',1,2,"Powers aren't supported yet"),('max(1, 2)',0,3,"Functions like round() aren't supported yet"),
  ('rent * 2',0,4,'Variable names start with $ (did you mean $rent?)'),('5;3',1,2,"Semicolons can't be used inside a formula"),
  ('1,250',1,2,None),('50%',2,3,None),('%5',0,1,None),('5 * round (2)',4,9,"Functions like round() aren't supported yet"),
  ('2 ^ -1',2,3,None),(',',0,1,None),('$rent%',5,6,None)]:
    if msg: e(t,'reserved_syntax',s,en,message=msg)
    else: e(t,'reserved_syntax',s,en)
# limits
v('1'+' '*497+'+1','2'); e('1'+' '*498+'+1','too_long',500,501)
v('1+'*99+'1','100'); e('1+'*100+'1','too_long',200,201); v('-'+'1+'*99+'1','98')
v('('*32+'1'+')'*32,'1'); e('('*33+'1'+')'*33,'too_deep',32,33)
v('-'*8+'5','5'); e('-'*9+'5','too_deep',8,9); v('-'*8+'5*'+'-'*8+'5','25')
# division by zero
e('1/0','division_by_zero',1,2,message='Division by zero'); e('1/(2-2)','division_by_zero',1,2)
e('$rent/($zero)','division_by_zero',5,6,message='Division by zero: $zero is 0'); e('0/0','division_by_zero',1,2)
e('1 / $zero * 2','division_by_zero',2,3); e('1 / $ZERO','division_by_zero',2,3,message='Division by zero: $zero is 0')
v('0/1','0')
# overflow
v('999999999999999 + 1','1000000000000000'); e('999999999999999 + 2','overflow',0,19,message='This works out too large')
v('1000000 * 1000000000','1000000000000000'); e('1000000 * 1000000001','overflow',0,20); e('-999999999999999 - 2','overflow',0,20)
e('1 / 0.0000000001 / 0.0000000001','overflow',0,31)
v('999999999999999 * 2 / 2','999999999999999') if False else e('999999999999999 * 2 / 2','overflow',0,19)
# out of range / whole numbers per field
e('-1 + 0','out_of_range',0,6,RT,message='At least 0%'); e('0 * 5','out_of_range',0,5,C,message='At least 1')
e('$weeks - 20','out_of_range',0,11,'loan.chargeDay',message='A day from 1 to 31'); v('$weeks - 21','31','loan.chargeDay')
e('7 / 2','not_whole',0,5,C); e('$weeks / 10','not_whole',0,11,'event.interval')
e('0 * 1','out_of_range',0,5,A,message='Enter an amount above zero'); e('1000000000000 * 1','out_of_range',0,17,A,message='At most $999,999,999,999.99')
v('999999999999.99 * 1','999999999999.99',A); v('0.004 + 0.001','0.01',A); e('0.004 * 1','out_of_range',0,9,A)
e('100000 + 1','out_of_range',0,10,C); v('100000 * 1','100000',C)
# variable values
e('1.12345678901','too_many_decimals',0,13,'variable.value'); p('1.1234567890','1.123456789','variable.value')
v('1 / 3','0.3333333333','variable.value'); v('-$rent / 7','-171.4285714286','variable.value')
# surrogate pairs / emoji
e('5 + 😀','unexpected_character',4,6); e('😀','unexpected_character',0,2); e('5😀','unexpected_character',1,3); e('$rent😀','unexpected_character',5,7)
# currency sigil
p('$5',  '5', A); v('$5 * 2','10',A); e('$5 * 2','unexpected_character',0,1,RT,message='Remove the $ from the number'); v('$.5 + $1','1.5',A)
p('$ 5','5',A); v('$5 * 2','10',S); e('2 * $3','unexpected_character',4,5,C)
# plain inputs (D14) and plain range messages
p('1,250.50','1250.5',A); p('A$1,250.50','1250.5',A); e('0','out_of_range',0,1,A,message='Enter an amount above zero')
e('-5','out_of_range',0,2,A,message='Use Money out instead of a negative amount'); p('','0','stream.threshold'); e('','empty',0,0,S,message='Enter an amount, e.g. 2500 or -120.50')
e('150','out_of_range',0,3,RT,message='At most 100%'); p('6.4','6.4',RT); p('1e3','1000','goal.amount'); p('2000','2000','goal.rate')
p('-5','-5','goal.startBalance'); p('','null','solve.total'); p('12','12',C); p(' 7 ','7','loan.chargeDay')
# hints
v('$rate * 3','16.5',A,hints=['percent_in_amount']); v('$rate / 100 * $rent','66',A,hints=[]); v('($rate) / 100 * 1000','55',A,hints=[])
v('$rent / 100','12',RT,hints=['money_in_rate']); v('$weeks * 2','104',C,hints=[]); v('$rate * 2','11',C,hints=['percent_in_amount'])
print(len(R))
json.dump(R, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'test', 'grammar_table.json'), 'w'), ensure_ascii=False, indent=1)
