var admin = angular.module('admin', ['ngResource', 'ngCookies']);

admin.config(function($routeProvider, $locationProvider){
    $routeProvider.when('/', {redirectTo: '/streams'});
    $routeProvider.when('/status', {controller: 'StatusCtrl', templateUrl: '/status.html'});
    $routeProvider.when('/streams', {controller: 'ListCtrl', templateUrl: '/streams.html'});
    $routeProvider.when('/streams/add', {controller: 'AddCtrl', templateUrl: '/streams-add.html'});
});

admin.factory('Stream', function($resource){
    return $resource('/stream/:id', {'id': '@id'});
});

admin.controller('ListCtrl', function($scope, Stream){
    $scope.searchText = '';
    $scope.streams = Stream.query();
});

admin.controller('AddCtrl', function($scope, Stream){
    $scope.stream = {
        id: 'ru-ah-fm',
        url: 'http://ru.ah.fm/'
    };

    $scope.add = function() {
        Stream.save($scope.stream, function(){
            console.log(arguments);
        });
    };
});

admin.controller('StatusCtrl', function($scope){

});
