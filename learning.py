import re
import sqlite3
import requests
from bs4 import BeautifulSoup
import xlwt
findLink = re.compile(r'<a href="(.*?)">')
headers = {
    "User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"
}
def getdata():
    for start_num in range(0,250,25):
    # start_num = 0
        url = 'https://movie.douban.com/top250?start='+str(start_num)
        response = requests.get(url,headers=headers)
        # print(response)
        content = response.text
        soup = BeautifulSoup(content,"html.parser")
        all_title=soup.findAll("span",attrs={"class":"title"})
        for title in all_title:
            if(title.string[1]!='/'):
                print(title.string)
def savedata():
    workbook = xlwt.Workbook(encoding="utf-8",style_compression=0)
    worksheet = workbook.add_sheet("Top250",cell_overwrite_ok=True)
    col = ("电影详情链接","图片链接","影片中文名","评分","评价数","概况","相关信息")
    for i in range(8):
        worksheet.write(0,i,col[i])
    for i in range(1,250):

    worksheet.write(0, 0, "hello")
    workbook.save("ces.xls")